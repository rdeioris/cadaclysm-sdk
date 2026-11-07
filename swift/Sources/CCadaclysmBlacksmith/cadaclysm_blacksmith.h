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
 * A point more than the tolerance outside the solid's boundary.
 */
#define CADACLYSM_BLACKSMITH_OUTSIDE 0

/**
 * A point more than the tolerance inside the solid's boundary.
 */
#define CADACLYSM_BLACKSMITH_INSIDE 1

/**
 * A point within the tolerance of the solid's exact boundary.
 */
#define CADACLYSM_BLACKSMITH_ON 2

/**
 * The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
 */
#define CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST 0

/**
 * `y1 + (y2 − y1) mu`: straight between neighbouring samples.
 */
#define CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR 1

/**
 * Linear at `mu' = (1 − cos(π mu)) / 2`: flat at every sample.
 */
#define CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE 2

/**
 * Bourke's cubic through every sample (C1 not promised; it does not reproduce a ramp).
 */
#define CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC 3

/**
 * Catmull-Rom: through every sample, C1, the tangent at each `(y2 − y0) / 2`.
 */
#define CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM 4

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
 * Also draw each solid's silhouettes -- where its surfaces turn away from the
 * eye, which no edge lies on, so a sphere gains an outline it otherwise has
 * none of. One group per solid, after that solid's lines.
 *
 * A line set in its own right: combine it with `EDGES`, `CURVES` or
 * `ISOCURVES` to draw an outline over them, or set it alone for an
 * outline-only drawing -- only naming nothing at all is refused. The
 * silhouettes are solved against the same eye the drawing
 * uses, at the page tolerance converted to the model's units. The eye does not
 * move when this bit is set; the page fit does, because the page is fitted to
 * everything drawn on it and the outline is new ink.
 */
#define CADACLYSM_BLACKSMITH_SVG_SILHOUETTES 16

/**
 * Entity kind: a point.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_ENTITY_POINT 0

/**
 * Entity kind: a line segment between two points.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_ENTITY_LINE 1

/**
 * Entity kind: a circle (a centre point and a radius).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_ENTITY_CIRCLE 2

/**
 * Entity kind: a circular arc (centre, start and end points).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_ENTITY_ARC 3

/**
 * Entity kind: a free curve (Bezier, conic or NURBS) through its own points.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_ENTITY_FREE_CURVE 4

/**
 * Constraint kind: two points at one place.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COINCIDENT 0

/**
 * Constraint kind: a point on a line (refs: point, line).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_LINE 1

/**
 * Constraint kind: a point on a circle or arc (refs: point, circle-or-arc).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_CIRCLE 2

/**
 * Constraint kind: two points at the same height.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL 3

/**
 * Constraint kind: two points at the same x.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL 4

/**
 * Constraint kind: two lines parallel.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PARALLEL 5

/**
 * Constraint kind: two lines perpendicular.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PERPENDICULAR 6

/**
 * Constraint kind: two lines on one infinite line.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COLLINEAR 7

/**
 * Constraint kind: two curves tangent (reads `sense`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT 8

/**
 * Constraint kind: a free curve tangent to another entity at one end (reads `end`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT_AT_END 9

/**
 * Constraint kind: two circles or arcs sharing a centre.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CONCENTRIC 10

/**
 * Constraint kind: two lines of equal length.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_LENGTH 11

/**
 * Constraint kind: two circles or arcs of equal radius.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_RADIUS 12

/**
 * Constraint kind: a point at the middle of a line (refs: point, line).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_MIDPOINT 13

/**
 * Constraint kind: two points mirrored about a line (refs: point, point, line).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_SYMMETRIC 14

/**
 * Constraint kind: an entity held where it is.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_FIX 15

/**
 * Dimension: the distance between two points (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DISTANCE 16

/**
 * Dimension: the distance from a point to a line (reads `value`, `driving`, `sense`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_LINE_DISTANCE 17

/**
 * Dimension: the distance between two parallel lines (reads `value`, `driving`, `sense`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LINE_DISTANCE 18

/**
 * Dimension: the gap between a circle and a line (reads `value`, `driving`, `sense`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_LINE_DISTANCE 19

/**
 * Dimension: the gap between two circles (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_DISTANCE 20

/**
 * Dimension: the x distance between two points (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL_DISTANCE 21

/**
 * Dimension: the y distance between two points (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL_DISTANCE 22

/**
 * Dimension: the length of a line (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LENGTH 23

/**
 * Dimension: the angle between two lines (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_ANGLE 24

/**
 * Dimension: the radius of a circle or arc (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_RADIUS 25

/**
 * Dimension: the diameter of a circle or arc (reads `value`, `driving`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DIAMETER 26

/**
 * Sense: the solver picks the side the geometry is already on.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_SENSE_AUTO 0

/**
 * Sense: the positive side.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_SENSE_POSITIVE 1

/**
 * Sense: the negative side.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_SENSE_NEGATIVE 2

/**
 * End: the start of a free curve.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_END_START 0

/**
 * End: the end of a free curve.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_END_END 1

/**
 * Solve status: every constraint is met.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATUS_CONVERGED 0

/**
 * Solve status: the constraints contradict each other (see `sketch_report_ids`).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATUS_CONFLICTING 1

/**
 * Solve status: the solver did not settle (see `sketch_report_ids` for the worst constraints).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATUS_DIVERGED 2

/**
 * Degrees-of-freedom state: movable (under-constrained).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATE_UNDER 0

/**
 * Degrees-of-freedom state: fully constrained.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATE_FULL 1

/**
 * Degrees-of-freedom state: over-constrained.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_STATE_OVER 2

/**
 * `sketch_dof_list`: the redundant constraints.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_DOF_REDUNDANT 0

/**
 * `sketch_dof_list`: the conflicting constraints.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_DOF_CONFLICTING 1

/**
 * `sketch_dof_list`: the entities that can still move.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_DOF_FREE_ENTITIES 2

/**
 * `sketch_dof_part_list`: the part's constraints.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_PART_CONSTRAINTS 0

/**
 * `sketch_dof_part_list`: the part's redundant constraints.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_PART_REDUNDANT 1

/**
 * `sketch_dof_part_list`: the part's conflicting constraints.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_PART_CONFLICTING 2

/**
 * `sketch_dof_part_list`: the part's entities that can still move.
 */
#define CADACLYSM_BLACKSMITH_SKETCH_PART_FREE_ENTITIES 3

/**
 * [`cadaclysm_blacksmith_solid_convert_to_nurbs`]'s level: the procedural surfaces
 * (revolutions, extrusions, sums).
 */
#define CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL 0

/**
 * The procedural surfaces and the quadrics (cylinder, cone, sphere, torus), so every curved face can be edited by its control points.
 */
#define CADACLYSM_BLACKSMITH_NURBS_ANALYTIC 1

/**
 * Everything, planes and edge curves too: a body made only of NURBS.
 */
#define CADACLYSM_BLACKSMITH_NURBS_ALL 2

/**
 * A line: `from[3] to[3]`, 6 doubles; `t` runs `0..1`.
 */
#define CADACLYSM_BLACKSMITH_VALUE_LINE 0

/**
 * A circle: `frame[12] radius`, 13 doubles; `t` the angle from the frame's x toward its y.
 */
#define CADACLYSM_BLACKSMITH_VALUE_CIRCLE 1

/**
 * An arc: `frame[12] radius t0 t1`, 15 doubles; the angle increasing, at most a full turn.
 */
#define CADACLYSM_BLACKSMITH_VALUE_ARC 2

/**
 * An ellipse: `frame[12] r1 r2`, 14 doubles; `r1` along x, `t` the eccentric angle.
 */
#define CADACLYSM_BLACKSMITH_VALUE_ELLIPSE 3

/**
 * A sphere: `frame[12] radius`, 13 doubles.
 */
#define CADACLYSM_BLACKSMITH_VALUE_SPHERE 4

/**
 * A cylinder: `frame[12] radius h0 h1`, 15 doubles; the height along z, increasing.
 */
#define CADACLYSM_BLACKSMITH_VALUE_CYLINDER 5

/**
 * A cone: `frame[12] radius height`, 14 doubles; the base in the frame's plane, the apex up z.
 */
#define CADACLYSM_BLACKSMITH_VALUE_CONE 6

/**
 * A torus: `frame[12] major minor`, 14 doubles; `minor < major`.
 */
#define CADACLYSM_BLACKSMITH_VALUE_TORUS 7

/**
 * An oriented box: `frame[12] x0 x1 y0 y1 z0 z1`, 18 doubles; each range increasing.
 */
#define CADACLYSM_BLACKSMITH_VALUE_CUBOID 8

/**
 * A rectangle: `frame[12] x0 x1 y0 y1`, 16 doubles; each range increasing. As a curve, its
 * boundary: `t` in `[0, 4]`, one unit a side from corner `(x0, y0)` counter-clockwise about z.
 */
#define CADACLYSM_BLACKSMITH_VALUE_RECTANGLE 9

/**
 * A triangle: `a[3] b[3] c[3]`, 9 doubles; not degenerate.
 */
#define CADACLYSM_BLACKSMITH_VALUE_TRIANGLE 10

/**
 * A ray: `position[3] direction[3]`, 6 doubles; the direction non-zero, kept as given.
 */
#define CADACLYSM_BLACKSMITH_VALUE_RAY 11

/**
 * A named tree of placed solids and sub-assemblies, written together as one
 * STEP file through [`cadaclysm_blacksmith_assembly_step`].
 *
 * Mutable: [`cadaclysm_blacksmith_assembly_place_solid`] and
 * [`cadaclysm_blacksmith_assembly_place_assembly`] add to it. A `place` call
 * must not run at the same time as any other call on the same assembly, or on
 * one placed anywhere below it -- placing an assembly does not copy it, it
 * shares the same handle's data (`Arc`), so a sub-assembly placed under two
 * parents is one piece of shared, mutable state and every caller of `place`
 * on it (through whichever parent) must serialise with every other. Placing
 * one assembly into another is additionally serialised process-wide, so two
 * threads placing `a` into `b` and `b` into `a` at once cannot both pass the
 * cycle check before either has recorded its placement. Freeing a handle does
 * not free an assembly that is still placed elsewhere: what a handle owns is
 * one reference to shared data, and the data lives until the last reference
 * -- placed or not -- lets go of it.
 */
typedef struct CadaclysmBlacksmithAssembly CadaclysmBlacksmithAssembly;

/**
 * One call's clashes, read one pair at a time or rebuilt without needing the
 * collider or the solids again. Immutable, and safe to read from any number of
 * threads at once; free with [`cadaclysm_blacksmith_clashes_free`].
 */
typedef struct CadaclysmBlacksmithClashes CadaclysmBlacksmithClashes;

/**
 * A closed solid meshed and indexed once, ready to classify points. Opaque; free with
 * [`cadaclysm_blacksmith_classifier_free`].
 *
 * It keeps its own reference to the body, so the solid it was built from may be freed first.
 * Build one per body for a grid of points: [`cadaclysm_blacksmith_contains`] meshes the body
 * on every call.
 */
typedef struct CadaclysmBlacksmithClassifier CadaclysmBlacksmithClassifier;

/**
 * Parts meshed once, asked pose after pose which of them interfere. Opaque;
 * free with [`cadaclysm_blacksmith_collider_free`].
 */
typedef struct CadaclysmBlacksmithCollider CadaclysmBlacksmithCollider;

/**
 * One [`cadaclysm_blacksmith_collider_check`] call's answer, read one pair at
 * a time ([`cadaclysm_blacksmith_collisions_hit`]) or rebuilt exactly
 * ([`cadaclysm_blacksmith_collisions_solid`]) without needing the collider
 * again. Immutable; free with [`cadaclysm_blacksmith_collisions_free`].
 */
typedef struct CadaclysmBlacksmithCollisions CadaclysmBlacksmithCollisions;

/**
 * A blacksmith document: nodes, parameters, history, branches and an evaluation cache. A
 * mutable object, like `CadaclysmBlacksmithSketch`: one thread at a time. Free it with
 * [`cadaclysm_blacksmith_document_free`].
 */
typedef struct CadaclysmBlacksmithDocument CadaclysmBlacksmithDocument;

/**
 * One solid meshed for a solver: opaque, owned, and freed with
 * [`cadaclysm_blacksmith_fem_mesh_free`].
 *
 * Made by [`cadaclysm_blacksmith_fem_mesh`]. Every pointer any accessor here writes is
 * borrowed from this handle and dies with it -- except the `.msh` text, which is the caller's
 * (see this module's own documentation).
 */
typedef struct CadaclysmBlacksmithFemMesh CadaclysmBlacksmithFemMesh;

/**
 * A heal report and the healed solid: owned data, opaque, independent of the solid it was made
 * from (it stays good after [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free)).
 * Made by [`cadaclysm_blacksmith_healed`], freed with [`cadaclysm_blacksmith_heal_free`].
 */
typedef struct CadaclysmBlacksmithHeal CadaclysmBlacksmithHeal;

/**
 * A health report: owned data, opaque, independent of the solid it was made from (it stays good
 * after [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free)). Made by
 * [`cadaclysm_blacksmith_health`], freed with [`cadaclysm_blacksmith_health_free`].
 */
typedef struct CadaclysmBlacksmithHealth CadaclysmBlacksmithHealth;

/**
 * What a verb did to its inputs' faces (or edges), read off the result's ids alone: see
 * [`cadaclysm_blacksmith_history`]. Immutable; free with
 * [`cadaclysm_blacksmith_history_free`].
 */
typedef struct CadaclysmBlacksmithHistory CadaclysmBlacksmithHistory;

/**
 * The hits of one call. Immutable; free with [`cadaclysm_blacksmith_hits_free`].
 */
typedef struct CadaclysmBlacksmithHits CadaclysmBlacksmithHits;

/**
 * Samples read at a fractional index. Opaque and immutable; free with
 * [`cadaclysm_blacksmith_interpolator_free`].
 */
typedef struct CadaclysmBlacksmithInterpolator CadaclysmBlacksmithInterpolator;

/**
 * The crossing of two solids, read one chain or one overlap at a time.
 * Immutable; free with [`cadaclysm_blacksmith_intersection_free`].
 */
typedef struct CadaclysmBlacksmithIntersection CadaclysmBlacksmithIntersection;

/**
 * A job: a stock, a safe height, its settings and the operations added so far.
 *
 * Mutable: every `job_set_*` call and every operation (`job_face`,
 * `job_contour`, `job_pocket`, `job_drill`) changes the handle in place, and a
 * refused call leaves it exactly as it was. Not shared with anything, and used
 * from one thread at a time. Free with [`cadaclysm_blacksmith_job_free`].
 */
typedef struct CadaclysmBlacksmithJob CadaclysmBlacksmithJob;

/**
 * The readings one [`cadaclysm_blacksmith_mesh_thickness`] call made.
 * Immutable; free with [`cadaclysm_blacksmith_mesh_thicknesses_free`].
 */
typedef struct CadaclysmBlacksmithMeshThicknesses CadaclysmBlacksmithMeshThicknesses;

/**
 * A curve in space, always a NURBS (lines, arcs and conics are exact rational NURBS).
 * Immutable; free with [`cadaclysm_blacksmith_nurbs_curve_free`].
 */
typedef struct CadaclysmBlacksmithNurbsCurve CadaclysmBlacksmithNurbsCurve;

/**
 * Every operation of a job, read back in order -- see
 * [`cadaclysm_blacksmith_job_operations`]. Immutable; free with
 * [`cadaclysm_blacksmith_operations_free`].
 */
typedef struct CadaclysmBlacksmithOperations CadaclysmBlacksmithOperations;

/**
 * An outline under construction: a start point and the segments drawn so far.
 * A mutable object, like `CadaclysmBlacksmithSweepPath` and
 * `CadaclysmBlacksmithAssembly`; unlike them, [`cadaclysm_blacksmith_path_end`]
 * consumes this one rather than leaving it live to be added to again.
 */
typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

/**
 * A closed 2D outline, with holes: what a sweep reads. Immutable, and safe to
 * use from any number of threads at once. The outline a viewer asks for
 * (`profile_polylines`) is cached on it, once per tolerance asked, and kept
 * until the profile is freed.
 */
typedef struct CadaclysmBlacksmithProfile CadaclysmBlacksmithProfile;

/**
 * Profiles a boolean, an offset, a section or a line of text produced. Immutable; free with
 * [`cadaclysm_blacksmith_profile_list_free`].
 */
typedef struct CadaclysmBlacksmithProfileList CadaclysmBlacksmithProfileList;

/**
 * Files a job wrote, in memory: each a tool number, a name and a text. Immutable;
 * the strings [`cadaclysm_blacksmith_programs_name`] and
 * [`cadaclysm_blacksmith_programs_text`] return are owned by the list and good
 * until [`cadaclysm_blacksmith_programs_free`].
 */
typedef struct CadaclysmBlacksmithPrograms CadaclysmBlacksmithPrograms;

/**
 * An R\*-tree over boxes with ids. Opaque; free with [`cadaclysm_blacksmith_rtree_free`].
 */
typedef struct CadaclysmBlacksmithRTree CadaclysmBlacksmithRTree;

/**
 * The hits of one query, in its order. Immutable; free with
 * [`cadaclysm_blacksmith_rtree_hits_free`].
 */
typedef struct CadaclysmBlacksmithRTreeHits CadaclysmBlacksmithRTreeHits;

/**
 * The pairs of one overlap query, ascending. Immutable; free with
 * [`cadaclysm_blacksmith_rtree_pairs_free`].
 */
typedef struct CadaclysmBlacksmithRTreePairs CadaclysmBlacksmithRTreePairs;

/**
 * A solid's regions, region 0 first. Immutable; free with
 * [`cadaclysm_blacksmith_regions_free`].
 */
typedef struct CadaclysmBlacksmithRegions CadaclysmBlacksmithRegions;

/**
 * What [`cadaclysm_blacksmith_job_machine`] left uncut, read back one item at a
 * time. Immutable; free with [`cadaclysm_blacksmith_report_free`].
 */
typedef struct CadaclysmBlacksmithReport CadaclysmBlacksmithReport;

/**
 * The samples one divide gave, in order along the edge or loop. Immutable; free with
 * [`cadaclysm_blacksmith_samples_free`].
 */
typedef struct CadaclysmBlacksmithSamples CadaclysmBlacksmithSamples;

/**
 * A constraint sketch: points, lines, circles, arcs and free curves joined by
 * geometric constraints and dimensions, solved on demand. A mutable object, like
 * `CadaclysmBlacksmithPath`: one thread at a time. Free it with
 * [`cadaclysm_blacksmith_sketch_free`].
 */
typedef struct CadaclysmBlacksmithSketch CadaclysmBlacksmithSketch;

/**
 * An exact B-rep solid (or open sheet), with its tessellation and edge table
 * cached on first ask. Immutable, and safe to read from any number of threads at
 * once: the caches fill behind a lock, and threads asking at one tolerance share
 * one tessellation. Meshing at another tolerance replaces it -- from any thread --
 * and frees the arrays already lent out, so threads meshing one solid at several
 * tolerances agree among themselves when that happens.
 */
typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

/**
 * The block of material a job cuts. Immutable; free with
 * [`cadaclysm_blacksmith_stock_free`].
 */
typedef struct CadaclysmBlacksmithStock CadaclysmBlacksmithStock;

/**
 * A Catmull-Clark control cage: positions, faces, creased edges, pinned
 * vertices, an optional mirror plane, and the selection of the edit that made
 * it. Opaque and immutable, and safe to read from any number of threads at
 * once; free with [`cadaclysm_blacksmith_subd_free`].
 */
typedef struct CadaclysmBlacksmithSubd CadaclysmBlacksmithSubd;

/**
 * A 3D path under construction: where it starts and its pieces in order. Read
 * by [`cadaclysm_blacksmith_sweep`] and [`cadaclysm_blacksmith_sweep_open`],
 * which borrow it -- unlike [`crate::profile::CadaclysmBlacksmithPath`], it is
 * not consumed by sweeping, only by nothing at all: free it yourself with
 * [`cadaclysm_blacksmith_sweep_path_free`].
 */
typedef struct CadaclysmBlacksmithSweepPath CadaclysmBlacksmithSweepPath;

/**
 * One call's swept clashes, read one pair at a time without needing the
 * collider or the solids again. Immutable, and safe to read from any number
 * of threads at once; free with [`cadaclysm_blacksmith_swept_clashes_free`].
 */
typedef struct CadaclysmBlacksmithSweptClashes CadaclysmBlacksmithSweptClashes;

/**
 * One tessellation of a solid, held: opaque, owned, and freed with
 * [`cadaclysm_blacksmith_tessellation_free`]. Its arrays belong to it, not to the solid --
 * meshing the solid again at another tolerance, or freeing the solid, leaves them where they
 * are. Immutable: any number of threads may read one at once.
 */
typedef struct CadaclysmBlacksmithTessellation CadaclysmBlacksmithTessellation;

/**
 * Solids meshed once at a tolerance and measured against each other. Immutable
 * once built, and safe to read from any number of threads at once; free with
 * [`cadaclysm_blacksmith_thickness_gauge_free`].
 */
typedef struct CadaclysmBlacksmithThicknessGauge CadaclysmBlacksmithThicknessGauge;

/**
 * The readings one gauge call made. Immutable; free with
 * [`cadaclysm_blacksmith_thicknesses_free`].
 */
typedef struct CadaclysmBlacksmithThicknesses CadaclysmBlacksmithThicknesses;

/**
 * A cutter and its feeds: a flat or ball end mill, or a drill. Immutable; free
 * with [`cadaclysm_blacksmith_tool_free`].
 */
typedef struct CadaclysmBlacksmithTool CadaclysmBlacksmithTool;

/**
 * A point at arc length: the point, the unit tangent there (zero where the curve stops), the
 * curve's own parameter, and an estimate of how far the arc length to it can be trusted.
 *
 * `segment` is `CADACLYSM_BLACKSMITH_NONE` on a solid's edge; on a profile it is the side the
 * point lies on, its segment index, or the segment count for the implicit closing side, and
 * `parameter` is that side's own (a line's 0..1, an arc's angle about its centre, a spline's
 * parameter). `from_polyline` is 1 where the curve was a sampled polyline: exact for its points,
 * not for whatever they were sampled from.
 */
typedef struct CadaclysmBlacksmithAt {
  double point[3];
  double tangent[3];
  double parameter;
  uint32_t segment;
  double error;
  int32_t from_polyline;
} CadaclysmBlacksmithAt;

/**
 * A pair that penetrates, touches, lies within the clearance, or could not be
 * decided, borrowed from the clashes handle: valid until it is freed. `kind`
 * is `"penetrating"`, `"touching"`, `"too_close"` or `"refused"`. `distance`
 * is the gap between the two boundaries (0 for penetrating and refused);
 * `on_a` and `on_b` are world points -- the closest pair, or for a penetrating
 * pair the centre of the overlap's world box (the origin for a refused one).
 * `kind_a`/`index_a`/`edge_a` (and `_b`) say what each point lies on exactly
 * as `CadaclysmBlacksmithClosest` does (`"face"`, `"edge"`, `"vertex"`;
 * `index` the kernel id; `edge` the edge-table row, `CADACLYSM_BLACKSMITH_NONE`
 * for a face, a vertex, and an edge with no row), and are `"none"` (index 0,
 * no edge) for a penetrating or refused pair. `refined` is 1 where the
 * distance is measured on the exact surfaces. `depth` is the thinnest side of
 * a penetrating pair's overlap box (0 otherwise); `text` says why a pair was
 * refused (`""` otherwise). `a` and `b` are part indices: for one set or a
 * collider `a < b`; for two sets `a` indexes the first and `b` the second.
 */
typedef struct CadaclysmBlacksmithClash {
  uint32_t a;
  uint32_t b;
  const char *kind;
  double distance;
  double on_a[3];
  double on_b[3];
  const char *kind_a;
  uint32_t index_a;
  uint32_t edge_a;
  const char *kind_b;
  uint32_t index_b;
  uint32_t edge_b;
  int32_t refined;
  double depth;
  const char *text;
} CadaclysmBlacksmithClash;

/**
 * A pair that clashes somewhere on the path, or could not be decided. `a` and
 * `b` are part indices: for one set or a collider `a < b`; for two sets `a`
 * indexes the first and `b` the second. `first_time` is the first time the pair
 * came within the clearance, in pose units (for a refused pair, the time it
 * was refused at); the pose-wise row there is row `i` of
 * `cadaclysm_blacksmith_swept_clashes_firsts`. `interval_count` is how many
 * time ranges the pair stays in clash (0 for a refused pair), read with
 * `cadaclysm_blacksmith_swept_clashes_interval`.
 */
typedef struct CadaclysmBlacksmithSweptClash {
  uint32_t a;
  uint32_t b;
  double first_time;
  uint32_t interval_count;
} CadaclysmBlacksmithSweptClash;

/**
 * An axis-aligned box: `lo` and `hi`, three doubles each.
 */
typedef struct CadaclysmBlacksmithBox {
  double lo[3];
  double hi[3];
} CadaclysmBlacksmithBox;

/**
 * Counts of one [`cadaclysm_blacksmith_collider_check`] call: the candidate
 * pairs `considered`, how many of them the world boxes and the oriented
 * boxes cleared, how many the share left to another call, how the rest were
 * answered (`cached`, `closed_form`, `meshed`), and how many were `refused`.
 * `confirmed` is the subset of `meshed` that were thin mesh-path overlaps
 * sent to `common` itself for a final answer (see the kernel's own doc).
 */
typedef struct CadaclysmBlacksmithColliderStats {
  uint32_t considered;
  uint32_t world_boxes;
  uint32_t oriented_boxes;
  uint32_t skipped_share;
  uint32_t cached;
  uint32_t closed_form;
  uint32_t meshed;
  uint32_t refused;
  uint32_t confirmed;
} CadaclysmBlacksmithColliderStats;

/**
 * A pair that interferes (`overlap` true), or could not be decided (`overlap`
 * false; `text` says why, `""` for an overlap). `positions` and `normals` are
 * `vertex_count` world xyz triples, three per triangle (unwelded); `indices`
 * is `index_count` entries; all empty (null, counts 0) for a refused pair.
 * `depth` is the thinnest side of the overlap's world box, 0 for a refused
 * pair.
 */
typedef struct CadaclysmBlacksmithCollisionHit {
  uint32_t a;
  uint32_t b;
  bool overlap;
  double depth;
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
  const char *text;
} CadaclysmBlacksmithCollisionHit;

/**
 * What a FEM mesh is meshed to.
 *
 * Zero it, set `size`, then set what you care about -- [`cadaclysm_blacksmith_fem_options_init`]
 * does the first two. A **null** pointer where one of these is expected means every default,
 * so `cadaclysm_blacksmith_fem_mesh(solid, NULL, NULL, NULL, NULL)` is the short way in.
 *
 * **`size` is how this struct grows**, and it is the reader library's `CadaclysmOpenOptions`
 * rule rather than this library's own `CadaclysmBlacksmithSvgOptions` one: set it to
 * `sizeof(CadaclysmBlacksmithFemOptions)` as **your** header declares it, and the library reads
 * the fields that fit inside it and defaults the rest. A caller built against an older header
 * works with a newer library, and one built against a newer header works with an older library
 * that stops reading at the end of what it knows. The rule that makes that hold, and the only
 * one: fields are appended, never reordered and never removed. `CadaclysmBlacksmithSvgOptions`
 * demands an exact match instead, which refuses both of those callers; the spec expects this
 * struct to grow a quality stage, which is the case the growth rule exists for.
 */
typedef struct CadaclysmBlacksmithFemOptions {
  /**
   * `sizeof(CadaclysmBlacksmithFemOptions)`. Zero, or anything shorter than the first
   * published struct, is refused rather than defaulted: that is uninitialised memory rather
   * than an old caller, and defaulting it would take whatever garbage sits in `tolerance`
   * for the figure [`cadaclysm_blacksmith_fem_options_init`] would have written there.
   */
  size_t size;
  /**
   * Chordal tolerance, model units: finite and above zero. **This alone governs how closely
   * the mesh follows the geometry.** Anything else is refused, with
   * [`cadaclysm_blacksmith_last_error`](crate::cadaclysm_blacksmith_last_error) saying so.
   */
  double tolerance;
  /**
   * A size ceiling, model units: finite and zero or more. `0` is no ceiling (curvature
   * alone). **It bounds the boundary and targets the interior**, which is not the same
   * thing as a longest element edge: it adds boundary nodes and does not refine boundary
   * geometry, and `CadaclysmBlacksmithFemMeshView::longest_edge` is what the mesh actually
   * came to -- the only figure that bounds the whole of it.
   */
  double max_size;
} CadaclysmBlacksmithFemOptions;

/**
 * Where a long operation reports: `phase` is a short static name ("snap",
 * "clip", ...), `done` of `total` steps within it, `user` whatever was passed
 * in. Called on the calling thread, often -- once per vertex in some phases --
 * so a sink that forwards elsewhere throttles itself. Must not call back into
 * this library. Null means silent.
 */
typedef void (*CadaclysmBlacksmithProgress)(const char *phase, size_t done, size_t total, void *user);

/**
 * The flat arrays of one FEM mesh, and its summary.
 *
 * Every pointer is **borrowed from the handle** and good until
 * [`cadaclysm_blacksmith_fem_mesh_free`]; none of them is a copy, and none of them is built by
 * the call that hands it over.
 *
 * The crossings -- triangles passing through each other -- are read through
 * `cadaclysm_blacksmith_fem_mesh_crossing_count` and `cadaclysm_blacksmith_fem_mesh_crossing`,
 * not a member here: callers allocate this struct, so it cannot grow.
 */
typedef struct CadaclysmBlacksmithFemMeshView {
  /**
   * Three doubles a node, placed, in `f64`.
   */
  const double *nodes;
  uint32_t node_count;
  /**
   * Three node indices a triangle, wound outward.
   */
  const uint32_t *triangles;
  uint32_t triangle_count;
  /**
   * The brep face each triangle lies on: one per triangle.
   */
  const uint32_t *triangle_face;
  /**
   * What each node lies on: `0` a vertex, `1` an edge, `2` a face. One per node.
   */
  const uint32_t *node_kind;
  /**
   * Which vertex, edge or face that is -- an index into this mesh's vertices, its edges or
   * the solid's faces, by the matching `node_kind`. One per node.
   */
  const uint32_t *node_entity;
  /**
   * The solid's faces; `triangle_face` and a `node_kind` of 2 index them. The same faces
   * [`cadaclysm_blacksmith_face_count`](crate::cadaclysm_blacksmith_face_count) counts.
   */
  uint32_t face_count;
  /**
   * The B-rep edges [`cadaclysm_blacksmith_fem_mesh_edge`] describes; a `node_kind` of 1
   * indexes them. **Not the same numbering as
   * [`cadaclysm_blacksmith_edge`](crate::cadaclysm_blacksmith_edge)**, which is the solid's
   * own edge table: these are the manifold analysis's, ascending by edge id.
   *
   * `CadaclysmBlacksmithFemEdge::id` carries the solid's own edge id for each of them, which is
   * the bridge from this numbering back to the topology -- to the brep, the censuses and the
   * `.msh` entities, though not to that geometric edge table.
   */
  uint32_t edge_count;
  /**
   * The B-rep vertices [`cadaclysm_blacksmith_fem_mesh_vertex`] describes; a `node_kind` of
   * 0 indexes them.
   */
  uint32_t vertex_count;
  /**
   * The cracks [`cadaclysm_blacksmith_fem_mesh_open_edge`] describes.
   */
  uint32_t open_edge_count;
  /**
   * The folds [`cadaclysm_blacksmith_fem_mesh_folded_edge`] describes.
   *
   * **A caller checking only `open_edge_count` calls a folded body sound.** The closure
   * census's own pinned rows are folds, not open cracks: a directed mesh edge used by more
   * than one triangle is a solid no thicker than a line, and it leaves no hole for an open
   * edge to find.
   */
  uint32_t folded_edge_count;
  /**
   * The topology is closed and the welded mesh is too. **False for every body whose topology
   * is not closed** (an open sheet from `face_sheet`, `drop_faces` or `extrude_open`), whose
   * mesh is then not asked about: such a body reports this false with `open_edge_count` and
   * `folded_edge_count` both zero, and *that trio together* says "not asked", not "nothing
   * found".
   */
  bool watertight;
  /**
   * Always false here, and kept so the two ABIs' views are the same struct: a solid always
   * has a brep behind it, so this library has no mesh-only body to report. The reader's
   * `cadaclysm_node_fem_mesh` sets it for a node with no brep (a JT, an STL, an OpenSCAD
   * body).
   */
  bool from_mesh;
  /**
   * The smallest interior angle of any triangle, in degrees.
   */
  double min_angle;
  /**
   * The triangle with that angle.
   */
  uint32_t worst_triangle;
  /**
   * The longest triangle edge, placed.
   *
   * **The figure to check against `CadaclysmBlacksmithFemOptions::max_size`, and the only one
   * that says what the mesh actually is**: `max_size` bounds the boundary segments and merely
   * targets the interior, and a `max_size` small enough to hit the mesher's own piece and
   * station ceilings is not honoured at all. A caller that asked for an element size reads
   * this to find out whether it got one.
   */
  double longest_edge;
} CadaclysmBlacksmithFemMeshView;

/**
 * One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks.
 */
typedef struct CadaclysmBlacksmithFemEdge {
  /**
   * Which B-rep edge this is, by the **solid's own** edge id -- `LoopTrim::edge` on the brep
   * behind the solid, the number its topology gives the edge.
   *
   * **Not this mesh's edge index**, which is what `CadaclysmBlacksmithFemMeshView::edge_count`
   * counts and everything else here means by an edge: a `node_kind` of 1 read through
   * `node_entity`, the third `uint32_t` of an open or folded census row, and the `edge_<i>`
   * physical group of the `.msh` text. The FEM edge list is a densely renumbered *subset* of
   * the solid's edges -- ascending by id, with every edge collapsed to a point left out -- so
   * a sphere, whose two pole runs collapse, reports its seam as edge **0** with an `id` of
   * **1**. This is the one field that leads from any of those numbers back to the solid's own
   * topology, and without it a caller holding `edge_7` out of a solver deck cannot say which
   * edge of the solid that is.
   *
   * **Nor is it a row of
   * [`cadaclysm_blacksmith_edge`](crate::cadaclysm_blacksmith_edge)**: that table is the
   * solid's edges grouped by geometry, one row per piece of curve, numbered by its own walk.
   * This id names the *topological* edge, which is what `.msh` entities, the censuses and the
   * brep all speak in.
   *
   * Saturating at `UINT32_MAX`, as every count in this ABI does, so an id past that would read
   * as [`CADACLYSM_BLACKSMITH_NONE`]; unreachable, an id being an index into the brep's own
   * edge table and a brep of 4e9 edges being terabytes of topology.
   */
  uint32_t id;
  /**
   * The edge's nodes in order along it, its end vertices included; a closed edge repeats no
   * node. Borrowed from the handle.
   */
  const uint32_t *nodes;
  uint32_t node_count;
  /**
   * Where each connected run of `nodes` begins: `[0]` for one chain along the whole edge --
   * the same offsets-into-a-flat-array shape as
   * `CadaclysmBlacksmithOverlap::loop_offsets`.
   *
   * **Read `nodes[runs[i] .. runs[i + 1]]` (the last run to the end) as one polyline and
   * join nothing across a boundary.** The two ends either side of one are two points of the
   * edge with no mesh edge between them -- a crack along the edge, or a stretch of it the
   * mesher sampled on one face only. One run is the ordinary answer; a caller reading
   * `nodes` as one polyline without looking here silently jumps the gap.
   */
  const uint32_t *runs;
  uint32_t run_count;
  /**
   * A face it bounds.
   */
  uint32_t face_a;
  /**
   * The other, or [`CADACLYSM_BLACKSMITH_NONE`] on an open sheet's rim. **`0` is a face, not
   * a sentinel**: an edge whose second face is face 0 reads `face_b == 0`.
   *
   * A non-manifold edge's third and further faces are not here.
   */
  uint32_t face_b;
  /**
   * A B-rep vertex its chain ends at, as [`cadaclysm_blacksmith_fem_mesh_vertex`] indexes
   * them.
   */
  uint32_t end_a;
  /**
   * The other, or [`CADACLYSM_BLACKSMITH_NONE`] where both ends are one vertex -- a closed
   * edge, a circle's rim, a full-turn seam. **`0` is a vertex, not a sentinel.**
   *
   * **Which end is `end_a` is the first trim's direction, and means nothing else.** The pair
   * bounds the edge; it does not orient it.
   */
  uint32_t end_b;
  /**
   * The nodes make one loop. False wherever `run_count` is more than one.
   */
  bool closed;
  /**
   * Bounded twice by one face: a closed surface's seam, not a real boundary. `face_a` and
   * `face_b` are then the same face.
   */
  bool seam;
} CadaclysmBlacksmithFemEdge;

/**
 * One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the topology
 * says it is, if that is known.
 *
 * One struct rather than three out-parameters: it matches the fill-an-out-struct-return-`bool`
 * shape of every sibling accessor here and in `intersection.rs`, it gives the header and every
 * wrapper a named type to pin a layout against, and it puts `node`'s sentinel beside
 * `has_position` where a caller reads both at once.
 */
typedef struct CadaclysmBlacksmithFemVertex {
  /**
   * The mesh node at this vertex, or [`CADACLYSM_BLACKSMITH_NONE`] where the mesh has none
   * there.
   *
   * **A sentinel here is ordinary, not a fault.** The analysis rebuilds a vertex wherever two
   * trims meet, and a pole's polyline runs give a sphere 48 of them where the mesh has 2
   * points; a caller walking these skips the sentinel rather than treating it as a gap.
   */
  uint32_t node;
  /**
   * Where the vertex is, in the same space and under the same placement as the view's
   * `nodes`. **Meaningless unless `has_position`** -- it is left zeroed in that case, and a
   * caller that reads it anyway reads a point no geometry has.
   */
  double point[3];
  /**
   * `point` was placed. False where every trim meeting at this vertex is a curve with no
   * geometry to read an end off -- then there is **no position at all**, reported as this
   * flag rather than as a plausible-looking `(0, 0, 0)` that a solver would take for a node
   * at the origin.
   */
  bool has_position;
} CadaclysmBlacksmithFemVertex;

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
 * One branch of one face pair's crossing, borrowed from the intersection
 * result: valid until it is freed. `points` is `point_count` xyz triples, in
 * walk order (a closed chain does not repeat its first point); `has_curve`
 * says whether `cadaclysm_blacksmith_intersection_curve` has anything for
 * this chain -- a tangent closed chain may have none (a closed chain that
 * does not go once round its curve is reported without one, `tangent`
 * still true, the points kept at their best estimate).
 */
typedef struct CadaclysmBlacksmithChain {
  const double *points;
  uint32_t point_count;
  uint32_t face_a;
  uint32_t face_b;
  bool closed;
  bool tangent;
  bool has_curve;
} CadaclysmBlacksmithChain;

/**
 * One edge's exact curve, borrowed from the solid: valid until it is freed.
 * See [`cadaclysm_blacksmith_edge_curve`]'s doc for the range convention and
 * what each field means for each `kind`.
 */
typedef struct CadaclysmBlacksmithCurve {
  /**
   * "line", "circle", "ellipse", "parabola", "hyperbola" or "nurbs". Static.
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
 * A region where a face of `a` and a face of `b` coincide, borrowed from the
 * intersection result: valid until it is freed. `points` is `point_count` xyz
 * triples, every ring back to back (outer first, holes after; two planes' common
 * region once, curved faces' `a`'s rings then `b`'s), each ring closed but not repeating its first point; `loop_offsets`
 * is `loop_count` starting indices into `points` counted in points, not
 * doubles, so ring `i` is `points[loop_offsets[i] .. loop_offsets[i + 1]]` and
 * the last ring runs to `point_count`. May carry zero rings (a partial overlap of curved faces
 * whose outlines cross).
 */
typedef struct CadaclysmBlacksmithOverlap {
  uint32_t face_a;
  uint32_t face_b;
  const double *points;
  const uint32_t *loop_offsets;
  uint32_t point_count;
  uint32_t loop_count;
} CadaclysmBlacksmithOverlap;

/**
 * A solid's mass properties, per unit density, each figure beside a bound on its own error.
 *
 * `closed`, `inverted`, `accuracy_met` and `from_mesh` are 1 or 0. The volume, the centroid and the
 * inertia are meaningful **only** where `closed` is 1; they are left at zero otherwise, and the area
 * is measured either way. Where `accuracy_met` is 0 the refinement gave up before reaching the
 * accuracy asked for: the figures are still honest, they are simply less certain than requested, and
 * the errors say by how much.
 *
 * `inertia` is row-major and symmetric, about the centroid, with the products of inertia negated
 * (`inertia[1] = -∫(x - gx)(y - gy) dV`). `principal_moments` ascend, and `principal_axes` is
 * row-major, unit and right-handed, the axis in row `i` belonging to moment `i`. Where two moments
 * agree inside `inertia_error` any orthonormal pair spanning their plane is as right as another.
 */
typedef struct CadaclysmBlacksmithMassProperties {
  int32_t closed;
  int32_t inverted;
  int32_t accuracy_met;
  int32_t from_mesh;
  double area;
  double area_error;
  double volume;
  double volume_error;
  double centroid[3];
  double centroid_error;
  double inertia[9];
  double inertia_error;
  double principal_moments[3];
  double principal_axes[9];
} CadaclysmBlacksmithMassProperties;

/**
 * A solid's box on its principal axes, per `cadaclysm_blacksmith_oriented_box`.
 *
 * `axes` is row-major, unit and right-handed, row `i` the direction of the extent `half[i]`;
 * `centre` is the middle of the box, which is not the centroid. The box is **not minimal**: it is
 * the tightest box aligned with the principal axes of inertia, and where two moments are equal (a
 * sphere, a cube) those axes are a free choice, so the box is one of many. The `half` extents are
 * grown by the tolerance the measurement settled on, so they may exceed the body's own extent by
 * about that much.
 */
typedef struct CadaclysmBlacksmithOrientedBox {
  double centre[3];
  double axes[9];
  double half[3];
} CadaclysmBlacksmithOrientedBox;

/**
 * A measured length beside the error it carries.
 *
 * `error` is an **estimate** of the difference from the true length, not a proof; where
 * `accuracy_met` is 1 it bounds the error in practice, and where it is 0 the refinement stopped at
 * its depth limit and the figure is less certain than was asked. `from_polyline` is 1 where the
 * curve was a sampled polyline: exact for its points, not for whatever they were sampled from.
 */
typedef struct CadaclysmBlacksmithLength {
  double length;
  double error;
  int32_t accuracy_met;
  int32_t from_polyline;
} CadaclysmBlacksmithLength;

/**
 * The closest points between two solids' boundaries, and what each lies on.
 *
 * `distance` is `|on_a - on_b|`. The **boundaries** are measured: a body wholly inside another
 * without touching it is the gap between their boundaries, not 0 (whether two solids overlap is a
 * different question), and boundaries that cross are 0 apart. Open bodies and sheets are accepted.
 *
 * `refined` is 1 when the points were refined onto the exact geometry: `distance` is then never
 * below the true minimum (both points are points of the bodies; an edge held only as a polyline
 * is measured on that polyline), and within the tolerance of it wherever the face pair holding
 * the minimum refines to its own nearest pair. It is 0 for the mesh's answer, which comes back
 * instead when a nearer candidate did not converge, or left its trims and its boundary search
 * found nothing: the distance is then within `[d - 2/3 tolerance, d + tolerance]` of the true
 * minimum `d`, and the points lie on the meshes, each within a third of the tolerance of its body.
 *
 * `kind_a`/`kind_b` are static strings, `"face"`, `"edge"` or `"vertex"` (never freed). `index_*`
 * is the kernel id: the face index, the edge id (a `FemEdge` id) or the topology vertex index (a
 * FEM vertex index). `edge_*` is, for an edge, the index into the list `cadaclysm_blacksmith_edge`
 * walks -- what `fillet` and `chamfer` take -- and `CADACLYSM_BLACKSMITH_NONE` for a face, a vertex,
 * and an edge with no row there (one the brep holds without an exact curve).
 */
typedef struct CadaclysmBlacksmithClosest {
  double distance;
  double on_a[3];
  double on_b[3];
  const char *kind_a;
  uint32_t index_a;
  uint32_t edge_a;
  const char *kind_b;
  uint32_t index_b;
  uint32_t edge_b;
  int32_t refined;
} CadaclysmBlacksmithClosest;

/**
 * One region of a solid: `finite` 0 for region 0, the infinite one, and 1 for every other;
 * `min` / `max` the box round the faces bounding it; `sides` how many face sides bound it (read
 * them with `cadaclysm_blacksmith_regions_side_at`); `shells` how many connected boundaries it
 * has: 1, plus one per void inside it.
 */
typedef struct CadaclysmBlacksmithRegion {
  int32_t finite;
  double min[3];
  double max[3];
  uint32_t sides;
  uint32_t shells;
} CadaclysmBlacksmithRegion;

/**
 * One side of one face bounding a region: `face` the face's index in the solid, `sense` +1 where
 * the region is the side the face's normal points to, -1 where it is the other side. A solid's
 * own inside is bounded by its faces at -1.
 */
typedef struct CadaclysmBlacksmithFaceSide {
  uint32_t face;
  int32_t sense;
} CadaclysmBlacksmithFaceSide;

/**
 * A curve's bending at a parameter: `kappa` (1 / radius), the unit tangent, the unit normal
 * toward the centre and the binormal (`tangent × normal`), and the centre of the osculating
 * circle. On a straight piece `kappa` is 0, `normal` and `binormal` are zero and
 * `has_centre` is 0.
 */
typedef struct CadaclysmBlacksmithCurvature {
  double kappa;
  double tangent[3];
  double normal[3];
  double binormal[3];
  double centre[3];
  int32_t has_centre;
} CadaclysmBlacksmithCurvature;

/**
 * How well two faces meet along their sides: the largest distance between the sides (`gap`),
 * the largest angle between their normals in radians, which way each faces aside (`angle`), the
 * largest difference of normal curvature square to the edge (`curvature`), each with where it
 * was found, and how many points along the first side were asked.
 */
typedef struct CadaclysmBlacksmithContinuity {
  double gap;
  double gap_at[3];
  double angle;
  double angle_at[3];
  double curvature;
  double curvature_at[3];
  uint32_t samples;
} CadaclysmBlacksmithContinuity;

/**
 * One side of the hole `cadaclysm_blacksmith_n_sided_patch` fills: side `side` (0 the face's
 * `u = 0` isocurve, 1 `u = 1`, 2 `v = 0`, 3 `v = 1`) of face `face` of `sheet`, over `from..to`
 * of the side's parameter (0..1 the whole side, 1..0 the whole side backwards), met at G`level`
 * (0, 1 or 2); or, where `sheet` is NULL, the curve `curve`, met at G0.
 */
typedef struct CadaclysmBlacksmithPatchBoundary {
  const struct CadaclysmBlacksmithSolid *sheet;
  uint32_t face;
  uint32_t side;
  double from;
  double to;
  uint32_t level;
  const struct CadaclysmBlacksmithNurbsCurve *curve;
} CadaclysmBlacksmithPatchBoundary;

/**
 * How well an N-sided patch meets: `faces` sub-patches; the worst `boundary` figures against
 * the neighbours (the gap over every side, the angle over those met at G1 or G2, the curvature
 * jump over those at G2) and the worst `internal` across the patch's own spokes; and the largest
 * `corner_angle` (radians) a corner of the hole leaves no patch able to meet -- zero where the
 * neighbours meet each other at G1 there.
 */
typedef struct CadaclysmBlacksmithPatchReport {
  uint32_t faces;
  struct CadaclysmBlacksmithContinuity boundary;
  struct CadaclysmBlacksmithContinuity internal;
  double corner_angle;
} CadaclysmBlacksmithPatchReport;

/**
 * What [`cadaclysm_blacksmith_join_sheets`] did. `sewn`: edges sewn, each two naked edges
 * become one shared edge. `naked_before`, `naked_after`: edges bordered by one face, before
 * the sewing (once the T-junctions are cut, so `naked_before - 2 * sewn == naked_after`) and
 * after. `refused`: groups of naked edges that share both ends but were left apart (too
 * far apart, or three or more of them). `turned`: faces whose sense the join turned.
 * `worst_gap`: the widest gap between two sewn edges, 0 where every edge met exactly.
 * `closed`: 1 where every edge is bordered twice and every vertex is one fan -- a solid.
 */
typedef struct CadaclysmBlacksmithJoinReport {
  uint32_t sewn;
  uint32_t naked_before;
  uint32_t naked_after;
  uint32_t refused;
  uint32_t turned;
  double worst_gap;
  int32_t closed;
} CadaclysmBlacksmithJoinReport;

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
 * [`CadaclysmBlacksmithMesh`] in `double`: the same tessellation (the index pointer is the
 * very one [`cadaclysm_blacksmith_mesh`] gives), positions and normals unnarrowed.
 */
typedef struct CadaclysmBlacksmithMesh64 {
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmBlacksmithMesh64;

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
   * `CADACLYSM_BLACKSMITH_SVG_EDGES` | `CURVES` | `ISOCURVES` |
   * `POLYLINES` | `SILHOUETTES`, with `EDGES | SILHOUETTES` the default.
   * The three line-set bits combine freely -- any one, any two or all three
   * (a solid has only edges to draw, so the other two change nothing here);
   * at least one of them or `SILHOUETTES` must be set.
   *
   * `SILHOUETTES` is on by default because a line set alone cannot draw
   * every body: a sphere's and a torus's only curves are their seams, which
   * are not edges and are never drawn, so `EDGES` alone gave those two a
   * blank page. Clear the bit for edges and nothing else.
   */
  uint32_t flags;
} CadaclysmBlacksmithSvgOptions;

/**
 * One trimmed face as the surface it actually is -- the fields of `CadaclysmFace`
 * (`cadaclysm-capi`), same order and layout: `cadaclysm_brep_gpu::ffi::RawFace`
 * ([`cadaclysm::gpu_pack::Face`]) byte for byte. See that struct's doc for what
 * each field means; it is not repeated here so the two never drift apart in prose
 * while their layouts are pinned in code below.
 */
typedef struct CadaclysmBlacksmithGpuFace {
  uint32_t kind;
  uint32_t reversed;
  uint32_t transposed;
  uint32_t reserved;
  float origin[4];
  float ax[4];
  float ay[4];
  float az[4];
  float domain[4];
  float scalars[4];
  uint32_t loop_start;
  uint32_t loop_count;
  uint32_t profile_start;
  uint32_t profile_count;
  uint32_t profile2_start;
  uint32_t profile2_count;
  uint32_t nurbs_start;
  uint32_t nurbs_count;
} CadaclysmBlacksmithGpuFace;

/**
 * A solid's exact faces packed for a GPU surface evaluator, and its exact edges: the record
 * the reader's `cadaclysm_node_gpu_surfaces` hands out for a part, for this solid. Every
 * array's length is in its own scalars (`u32` or `float`): `faces` is `face_count` records
 * ([`CadaclysmBlacksmithGpuFace`]); `loops` two words a loop; `points` two floats a point;
 * `profiles` four a sample; `tiles` two words a face (the tile grid `nu, nv`); `tile_domains`
 * four floats a tile; `tile_samples` the density samples, three floats a point; `tile_boxes`
 * six floats a tile; `edges` sixteen floats a rational cubic (four xyz points, four weights).
 * Positions are about `about`; `bounds` (min xyz, max xyz) alone is in the solid's own
 * coordinates. `surface_count` is the faces packed, one colour slot each.
 */
typedef struct CadaclysmBlacksmithGpuSurfaces {
  const struct CadaclysmBlacksmithGpuFace *faces;
  uint32_t face_count;
  uint32_t surface_count;
  const uint32_t *loops;
  uint32_t loops_len;
  const float *points;
  uint32_t points_len;
  const float *profiles;
  uint32_t profiles_len;
  const float *nurbs;
  uint32_t nurbs_len;
  const uint32_t *shared;
  uint32_t shared_len;
  const uint32_t *tiles;
  uint32_t tiles_len;
  const float *tile_domains;
  uint32_t tile_domains_len;
  const float *tile_samples;
  uint32_t tile_samples_len;
  const float *tile_boxes;
  uint32_t tile_boxes_len;
  const float *edges;
  uint32_t edges_len;
  double bounds[6];
  double about[3];
} CadaclysmBlacksmithGpuSurfaces;

/**
 * One edge of a solid, borrowed from it: valid until the solid is freed.
 */
typedef struct CadaclysmBlacksmithEdge {
  /**
   * "line", "circle", "ellipse", "parabola", "hyperbola", "nurbs" or "other". Static.
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
 * One answer of a search, `within` or `nearest`: the entry's id and the distance from the query
 * point to its box (0 inside it, and 0 for every search hit).
 */
typedef struct CadaclysmBlacksmithRTreeHit {
  uint32_t id;
  double distance;
} CadaclysmBlacksmithRTreeHit;

/**
 * One overlapping pair: `a` and `b` are entry ids (`a` from the first tree for
 * `cadaclysm_blacksmith_rtree_overlaps`, `a <= b` for `..._self_overlaps`).
 */
typedef struct CadaclysmBlacksmithRTreePair {
  uint32_t a;
  uint32_t b;
} CadaclysmBlacksmithRTreePair;

/**
 * A cage's parts, as views into its handle: valid until the handle is freed.
 * `positions` is `3 * vertex_count` doubles; `face_sizes` is `face_count`
 * vertex counts and `face_indices` their loops one after another
 * (`index_count`, the sum of `face_sizes`); `creases` is `2 * crease_count`
 * vertex ids, each pair smaller first, sorted; `pins` is `pin_count` vertices.
 * `symmetry_axis` is -1 for none, 0 X, 1 Y, 2 Z, and `symmetry_tolerance` the
 * on-plane distance of a mirrored half (0 when none). `selection_kind` is what
 * the edit that made this handle selected (0 vertices, 1 edges, 2 faces, 3
 * none), and `selection` its `selection_count` ids, an edge selection as
 * `2 * selection_count` vertex ids.
 */
typedef struct CadaclysmBlacksmithSubdParts {
  const double *positions;
  uint32_t vertex_count;
  const uint32_t *face_sizes;
  uint32_t face_count;
  const uint32_t *face_indices;
  uint32_t index_count;
  const uint32_t *creases;
  uint32_t crease_count;
  const uint32_t *pins;
  uint32_t pin_count;
  int32_t symmetry_axis;
  double symmetry_tolerance;
  uint32_t selection_kind;
  const uint32_t *selection;
  uint32_t selection_count;
} CadaclysmBlacksmithSubdParts;

/**
 * A cage's smooth surface at one level, as views valid until the handle is
 * freed, from any thread: each level's mesh is made once and kept (at most
 * six), so asking for another level never frees one already lent out. `positions` and `normals` are `3 * vertex_count` doubles:
 * limit positions and unit outward limit normals. `indices` is `index_count`
 * vertex ids, three per triangle, and `triangle_face` `index_count / 3`
 * entries: the face of the *full* cage each triangle lies on (on a mirrored
 * half, face `f` of the half is `f` and its reflection `f + face_count`).
 */
typedef struct CadaclysmBlacksmithSubdMesh {
  const double *positions;
  uint32_t vertex_count;
  const double *normals;
  const uint32_t *indices;
  uint32_t index_count;
  const uint32_t *triangle_face;
} CadaclysmBlacksmithSubdMesh;

/**
 * What [`cadaclysm_blacksmith_subd_to_solid`] did and how close it came:
 * `regular` patches exact from their own net and `refined` ones from a refined
 * neighbourhood, the Catmull-Clark `steps` taken first (1 or 2), and `levels`,
 * the deepest local refinement a patch took (0 when none was refined). The
 * largest `deviation` from the limit surface, as a fraction of the cage's
 * bounding-box diagonal, and the largest tangent break `g1_angle_deg` across a
 * side that is not creased, in degrees, with the world points they were
 * measured at.
 */
typedef struct CadaclysmBlacksmithSubdReport {
  uint32_t regular;
  uint32_t refined;
  uint32_t steps;
  uint32_t levels;
  double deviation;
  double g1_angle_deg;
  double deviation_at[3];
  double g1_at[3];
} CadaclysmBlacksmithSubdReport;

/**
 * A body's measuring mesh, borrowed from the gauge (valid until it is freed):
 * `vertex_count` vertices of three doubles each in `positions` and `normals`
 * (unit, outward; no vertex is shared between two B-rep faces),
 * `triangle_count` triangles of three indices each in `indices`, and the B-rep
 * face of each triangle in `faces`. A reading's `vertex` indexes this mesh.
 */
typedef struct CadaclysmBlacksmithThicknessMesh {
  const double *positions;
  const double *normals;
  const uint32_t *indices;
  const uint32_t *faces;
  uint32_t vertex_count;
  uint32_t triangle_count;
} CadaclysmBlacksmithThicknessMesh;

/**
 * One thickness for a face. `found` false means nothing found
 * (no reading under the maximum, or an `at` whose foot is off the face): the
 * numbers are then NaN and `uniform` false. Otherwise `thickness` is the
 * median of the face's vertex readings (or the reading at `at`), `min` and
 * `max` their extremes, and `uniform` is `max - min` within the tolerance.
 */
typedef struct CadaclysmBlacksmithFaceThickness {
  bool found;
  double thickness;
  double min;
  double max;
  bool uniform;
} CadaclysmBlacksmithFaceThickness;

/**
 * One reading on a solid. `point` lies on face `face` of body `body` (a vertex
 * of its measuring mesh, `vertex`; `CADACLYSM_BLACKSMITH_NONE` for a reading at
 * a point, `_thickness_gauge_at`). `thickness` is the nearest-opposing-wall rule (the nearest triangle that
 * faces against one of the vertex's own faces, with the vertex behind it) on the measuring
 * mesh, to `opposite` on face `opposite_face` of body `opposite_body`; `knife`
 * marks a knife edge (thickness 0, `opposite` = `point`). `exact_opposite` is
 * `opposite` moved onto its exact face where its foot lies within the
 * tolerance and inside the face's trims, `exact_thickness` the distance to it.
 * `sphere` is the diameter of the largest ball tangent at `point` that holds
 * none of the surfaces, NaN where none under the maximum does (0 on a knife
 * edge).
 */
typedef struct CadaclysmBlacksmithThickness {
  uint32_t body;
  uint32_t vertex;
  uint32_t face;
  double point[3];
  double thickness;
  double opposite[3];
  uint32_t opposite_body;
  uint32_t opposite_face;
  bool knife;
  double exact_thickness;
  double exact_opposite[3];
  double sphere;
} CadaclysmBlacksmithThickness;

/**
 * One reading on a plain mesh: vertex `vertex` of mesh `mesh`, at `point`,
 * reads `thickness` to `opposite` on triangle `opposite_triangle` of mesh
 * `opposite_mesh` (both indices within that mesh). `knife`: a knife edge,
 * thickness 0 and `opposite` = `point`.
 */
typedef struct CadaclysmBlacksmithMeshThickness {
  uint32_t mesh;
  uint32_t vertex;
  double thickness;
  double point[3];
  double opposite[3];
  uint32_t opposite_mesh;
  uint32_t opposite_triangle;
  bool knife;
} CadaclysmBlacksmithMeshThickness;

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
 * A colour's text as r, g, b in 0..1, into `out[0..3]`: `"#rgb"`, `"#rrggbb"`
 * (the `#` optional) or one of the 148 CSS colour names, any case. The one
 * parser every wrapper hands colour text to, so the forms are the same in each.
 * False, with [`cadaclysm_blacksmith_last_error`] saying why, for anything else.
 *
 * # Safety
 * `text` a NUL-terminated string; `out` room for three doubles.
 */
bool cadaclysm_blacksmith_parse_colour(const char *text, double *out);

/**
 * Sets a kernel option, by its name, for the whole process from the next call on.
 * The options are numbers under stable names (`"boolean.mesh_budget"`,
 * `"boolean.finest_tolerance"`, `"profile_boolean.point_budget"`,
 * `"measure.default_accuracy"`, `"tolerance.relative"`, `"tolerance.angular"`,
 * `"step.validation_properties"`, `"step.validation_accuracy"`; the error for a
 * wrong value says what each takes; the two tolerance options are explained at
 * [`cadaclysm_blacksmith_effective_tolerance`]): one call for all of them, so an
 * option added later needs no new entry point -- which is how
 * [`cadaclysm_blacksmith_step`]'s validation properties reach every language
 * without one. False -- and nothing changed -- for a name that is not an option or a
 * value it does not take, with [`cadaclysm_blacksmith_last_error`] saying which
 * and what it takes.
 *
 * # Safety
 * `name` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_option_set(const char *name, double value);

/**
 * A kernel option's value, by its name, into `*out`: what was last set, else its
 * default. False for a name that is not an option, with
 * [`cadaclysm_blacksmith_last_error`] listing the ones there are.
 *
 * # Safety
 * `name` a NUL-terminated string; `out` room for one double.
 */
bool cadaclysm_blacksmith_option_get(const char *name, double *out);

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
 * The point at arc length `s` along edge `edge` of `solid` (the index `cadaclysm_blacksmith_edge_length`
 * takes), from the start of the range its `edge_curve` row reports, into `out`. `s` lies in
 * `[0, length]`; past either end by no more than the length's error is that end.
 *
 * `false` and `last_error` for a null solid or `out`, an edge past the end of the table or with no
 * exact curve, an `s` outside the edge, and an `accuracy` that is NaN, infinite, or 1 or more.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithAt`.
 */
bool cadaclysm_blacksmith_edge_point_at_length(const struct CadaclysmBlacksmithSolid *solid,
                                               uint32_t edge,
                                               double s,
                                               double accuracy,
                                               struct CadaclysmBlacksmithAt *out);

/**
 * Edge `edge` of `solid` in `n` pieces of equal arc length: `n + 1` samples from its start to its
 * end, or `n` for an edge that closes on itself (its range is its curve's whole closed loop: a
 * whole circle or ellipse, a closed spline's whole domain), whose end is its start again. The
 * first sample is exactly the range's start.
 *
 * Null and `last_error` for a null solid, an edge past the end or with no exact curve, an `n` of 0
 * or above 1 000 000, and an `accuracy` that is NaN, infinite, or 1 or more.
 *
 * # Safety
 * `solid` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_count(const struct CadaclysmBlacksmithSolid *solid,
                                                                             uint32_t edge,
                                                                             uint32_t n,
                                                                             double accuracy);

/**
 * Samples of edge `edge` of `solid` every `step` of arc length from its start; the last piece is
 * whatever is left over, the end a sample only where a step lands on it, and an edge that closes
 * on itself never repeats its start.
 *
 * Null and `last_error` for a null solid, an edge past the end or with no exact curve, a `step`
 * not positive and finite or giving more than 1 000 000 samples, and an `accuracy` that is NaN,
 * infinite, or 1 or more.
 *
 * # Safety
 * `solid` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_length(const struct CadaclysmBlacksmithSolid *solid,
                                                                              uint32_t edge,
                                                                              double step,
                                                                              double accuracy);

/**
 * The point at arc length `s` along `profile`'s outer loop from its start, into `out`; `segment`
 * names the side it lies on. `false` and `last_error` for a null profile or `out`, an `s` outside
 * `[0, perimeter]`, and an `accuracy` that is NaN, infinite, or 1 or more.
 *
 * # Safety
 * `profile` live; `out` one `CadaclysmBlacksmithAt`.
 */
bool cadaclysm_blacksmith_profile_point_at_length(const struct CadaclysmBlacksmithProfile *profile,
                                                  double s,
                                                  double accuracy,
                                                  struct CadaclysmBlacksmithAt *out);

/**
 * `profile`'s outer loop in `n` pieces of equal arc length: `n` samples from its start, the loop
 * being closed. Null and `last_error` for a null profile, an `n` of 0 or above 1 000 000, and an
 * `accuracy` that is NaN, infinite, or 1 or more.
 *
 * # Safety
 * `profile` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_count(const struct CadaclysmBlacksmithProfile *profile,
                                                                                uint32_t n,
                                                                                double accuracy);

/**
 * Samples of `profile`'s outer loop every `step` of arc length from its start, the last piece
 * whatever is left over and the start never repeated. Null and `last_error` for a null profile, a
 * `step` not positive and finite or giving more than 1 000 000 samples, and an `accuracy` that is
 * NaN, infinite, or 1 or more.
 *
 * # Safety
 * `profile` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_length(const struct CadaclysmBlacksmithProfile *profile,
                                                                                 double step,
                                                                                 double accuracy);

/**
 * How many samples. 0 (and `last_error`) for null.
 *
 * # Safety
 * `samples` live.
 */
uint32_t cadaclysm_blacksmith_samples_count(const struct CadaclysmBlacksmithSamples *samples);

/**
 * Sample `i` into `out`. `false` (and `last_error`) for a null `samples`, a null `out`, or `i` not
 * below the count.
 *
 * # Safety
 * `samples` live; `out` one `CadaclysmBlacksmithAt`.
 */
bool cadaclysm_blacksmith_samples_at(const struct CadaclysmBlacksmithSamples *samples,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithAt *out);

/**
 * Release a samples list. Null is a no-op.
 *
 * # Safety
 * `samples` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_samples_free(struct CadaclysmBlacksmithSamples *samples);

/**
 * `solid`, named `name` -- see [`cadaclysm_blacksmith_solid_name`] and, for what
 * a name is used for, `cadaclysm-blacksmith-abi`'s `assembly` module. Refused
 * (null, `last_error`) for an empty name; a name cannot contain a NUL, since it
 * is read as a NUL-terminated C string in the first place.
 *
 * # Safety
 * `solid` live; `name` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_named(const struct CadaclysmBlacksmithSolid *solid,
                                                            const char *name);

/**
 * `solid`'s name, or null when it has none. Borrowed: good until `solid` is
 * freed, and must not be freed itself.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_solid_name(const struct CadaclysmBlacksmithSolid *solid);

/**
 * `solid` made of `material`: the material's name, written as STEP's
 * `MATERIAL_DESIGNATION` on the solid's product by [`cadaclysm_blacksmith_step`]
 * and [`cadaclysm_blacksmith_assembly_step`] (moving the default schema to AP242,
 * as a colour does; dropped under a named schema without it, as a colour is).
 * Kept by moves, booleans and every other operation, as the solid's colour is: a
 * result made from several solids is made of the first's. Refused (null,
 * `last_error`) for a blank name.
 *
 * # Safety
 * `solid` live; `material` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_material(const struct CadaclysmBlacksmithSolid *solid,
                                                                    const char *material);

/**
 * `solid`'s material, or null when it has none. Borrowed: good until `solid` is
 * freed, and must not be freed itself.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_solid_material(const struct CadaclysmBlacksmithSolid *solid);

/**
 * `solid` drawn in a style defined outside the file: `identification` the style's
 * name in the library at `location` -- a MaterialX or MDL file and a material in
 * it, say. Either may be null, not both. Written as STEP's
 * `EXTERNALLY_DEFINED_STYLE` beside the solid's colour, which a reader without
 * the library draws instead; needs a schema with it (AP242, AP214 -- the default
 * moves to AP242), dropped under one without. Kept by operations as
 * [`cadaclysm_blacksmith_with_material`]'s material is. Refused (null,
 * `last_error`) when both are null or blank.
 *
 * # Safety
 * `solid` live; `location` and `identification` each null or a NUL-terminated
 * UTF-8 string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_styled(const struct CadaclysmBlacksmithSolid *solid,
                                                             const char *location,
                                                             const char *identification);

/**
 * The location of `solid`'s external style ([`cadaclysm_blacksmith_styled`]), or
 * null when it has none. Borrowed, as [`cadaclysm_blacksmith_solid_material`]'s.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_solid_style_location(const struct CadaclysmBlacksmithSolid *solid);

/**
 * The identification of `solid`'s external style ([`cadaclysm_blacksmith_styled`]),
 * or null when it has none. Borrowed, as [`cadaclysm_blacksmith_solid_material`]'s.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_solid_style_identification(const struct CadaclysmBlacksmithSolid *solid);

/**
 * A new, empty assembly called `name`. Free it with
 * [`cadaclysm_blacksmith_assembly_free`]. Null and `last_error` for an empty
 * name.
 *
 * # Safety
 * `name` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_new(const char *name);

/**
 * Release an assembly handle. Null is a no-op. Does **not** free the assembly
 * itself if it is still placed somewhere else (see the handle's own doc) --
 * only this one reference to it.
 *
 * # Safety
 * `assembly` must have come from this library and not have been freed
 * already.
 */
void cadaclysm_blacksmith_assembly_free(struct CadaclysmBlacksmithAssembly *assembly);

/**
 * `assembly`'s name. Borrowed: good until `assembly` is freed, and must not
 * be freed itself.
 *
 * # Safety
 * `assembly` live.
 */
const char *cadaclysm_blacksmith_assembly_name(const struct CadaclysmBlacksmithAssembly *assembly);

/**
 * Place `solid` at `frame` (twelve doubles, as every `frame` argument; must be
 * right-handed and orthonormal) in `assembly`, called `name` -- or, with
 * `name` null, `solid`'s own name (`"part"` if it has none), numbered past
 * any already taken in `assembly` (`"bolt"`, `"bolt 2"`, ...). An explicit
 * `name` already taken in `assembly` is refused. Returns the placement's
 * name, owned: free it with [`cadaclysm_blacksmith_string_free`]. Null and
 * `last_error` on failure.
 *
 * # Safety
 * `assembly` and `solid` live; `frame` twelve doubles; `name` null or a
 * NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_assembly_place_solid(struct CadaclysmBlacksmithAssembly *assembly,
                                                const struct CadaclysmBlacksmithSolid *solid,
                                                const double *frame,
                                                const char *name);

/**
 * As [`cadaclysm_blacksmith_assembly_place_solid`], but placing another
 * assembly, `placed`, rather than a solid -- sharing it, not copying it, so a
 * later `place` on `placed` (through this parent or another) shows up
 * wherever it is placed. Refused (null, `last_error` naming the cycle) if
 * `placed` is `assembly` itself or anywhere above it in the tree already,
 * since writing that out would never terminate.
 *
 * # Safety
 * `assembly` and `placed` live; `frame` twelve doubles; `name` null or a
 * NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_assembly_place_assembly(struct CadaclysmBlacksmithAssembly *assembly,
                                                   const struct CadaclysmBlacksmithAssembly *placed,
                                                   const double *frame,
                                                   const char *name);

/**
 * `assembly`, and everything placed under it, as one STEP file: `assembly`
 * the root product, each sub-assembly and each distinct part (the same solid
 * with the same paint and name) written once, each placement an occurrence
 * named as it was placed. `schema` and `unit` as for
 * [`cadaclysm_blacksmith_step`]. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure --
 * including an assembly reachable from this one that places nothing, since a
 * reader would never show it.
 *
 * # Safety
 * `assembly` live; `schema` null or a NUL-terminated string.
 */
char *cadaclysm_blacksmith_assembly_step(const struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *schema,
                                         uint32_t unit);

/**
 * `assembly`, and everything placed under it, as one Rhino `.3dm`: each distinct part
 * (the same solid with the same paint and name, as [`cadaclysm_blacksmith_assembly_step`]
 * counts them) a block holding its body, each sub-assembly a block of references to
 * what it places -- so nested assemblies are nested blocks -- and this assembly's own
 * placements references at the top of the file, on a layer named after it. Each
 * reference is named as its placement was; block names are the parts' and
 * assemblies' names made ones Rhino takes and numbered past any already taken,
 * regardless of case (`bolt`, `bolt 2`). A body is written as
 * [`cadaclysm_blacksmith_3dm_bytes`] writes a solid's. `unit` as for
 * [`cadaclysm_blacksmith_step`].
 *
 * The bytes are owned, their count written through `len`: release them with
 * [`cadaclysm_blacksmith_bytes_free`]. Null and `last_error` on failure -- including
 * an assembly reachable from this one that places nothing. On success `last_error`
 * lists what was written as a mesh or left out, one line each, or is null.
 *
 * # Safety
 * `assembly` live; `len` a writable `size_t`.
 */
uint8_t *cadaclysm_blacksmith_assembly_3dm_bytes(const struct CadaclysmBlacksmithAssembly *assembly,
                                                 uint32_t unit,
                                                 size_t *len);

/**
 * [`cadaclysm_blacksmith_assembly_3dm_bytes`] written to `path`, replacing any file
 * there. `false` and `last_error` on failure, including the file's; on success
 * `last_error` says what was written as a mesh or left out, as that call's does.
 *
 * # Safety
 * `assembly` live; `path` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_assembly_3dm(const struct CadaclysmBlacksmithAssembly *assembly,
                                       const char *path,
                                       uint32_t unit);

/**
 * Declare a rigid link `name` over this assembly's placements named in `placements`
 * (`placement_count` of them). False, with `last_error` saying why, when a rule of
 * `Assembly.link` refuses it; the assembly is then unchanged.
 *
 * # Safety
 * `assembly` a live assembly; `name` and each of `placements`' `placement_count`
 * entries NUL-terminated UTF-8; `placements` may be null only when the count is 0.
 */
bool cadaclysm_blacksmith_assembly_link(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *name,
                                        const char *const *placements,
                                        size_t placement_count);

/**
 * Connect this assembly's links `start` and `end` (kept in that order) as a joint
 * called `name`. False, with `last_error` saying why, when a rule of `Assembly.joint`
 * refuses it; the assembly is then unchanged.
 *
 * # Safety
 * `assembly` a live assembly; `name`, `start` and `end` NUL-terminated UTF-8.
 */
bool cadaclysm_blacksmith_assembly_joint(struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *name,
                                         const char *start,
                                         const char *end);

/**
 * Gives joint `joint` its pair -- see `abi::Assembly::pair` for the
 * rules. `frame` and `end_frame` are each twelve doubles, as every frame argument;
 * a null `end_frame` means `frame` itself. `lower`/`upper` hold `freedom_count`
 * doubles each and `has_lower`/`has_upper` `freedom_count` flags; all four null
 * with `freedom_count` 0 means no ranges given. `pitch` is NaN for every kind but
 * `screw`, which requires a real, non-zero pitch. False, with `last_error` saying
 * why, when a rule refuses it; the assembly is then unchanged.
 *
 * # Safety
 * `assembly` a live assembly; `joint` and `kind` NUL-terminated UTF-8; `frame`
 * twelve doubles; `end_frame` null or twelve doubles; `lower`, `upper`, `has_lower`
 * and `has_upper` either all null (with `freedom_count` 0) or each pointing at
 * `freedom_count` entries.
 */
bool cadaclysm_blacksmith_assembly_pair(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *joint,
                                        const char *kind,
                                        const double *frame,
                                        const double *end_frame,
                                        const double *lower,
                                        const double *upper,
                                        const bool *has_lower,
                                        const bool *has_upper,
                                        size_t freedom_count,
                                        double pitch);

/**
 * [`cadaclysm_blacksmith_assembly_pair`] with the kind's parameters in place of the
 * pitch -- see `abi::Assembly::pair_with`: `screw` `[pitch]`; `rack_and_pinion`
 * `[pinion_radius]`; `gear` `[radius_first, radius_second, ratio]` or those plus
 * `[bevel, helical_angle]` (radians), the ratio the second link's rotation over the
 * first's, signed; no parameters (`param_count` 0, `params` null) for any other kind.
 * Every other argument reads as in `cadaclysm_blacksmith_assembly_pair`. False, with
 * `last_error` saying why, when a rule refuses it -- a wrong parameter count among
 * them; the assembly is then unchanged.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_assembly_pair`]; `params` null or `param_count` doubles.
 */
bool cadaclysm_blacksmith_assembly_pair_with(struct CadaclysmBlacksmithAssembly *assembly,
                                             const char *joint,
                                             const char *kind,
                                             const double *frame,
                                             const double *end_frame,
                                             const double *lower,
                                             const double *upper,
                                             const bool *has_lower,
                                             const bool *has_upper,
                                             size_t freedom_count,
                                             const double *params,
                                             size_t param_count);

/**
 * Adds a named state to `assembly` -- see `abi::Assembly::state` and the Global
 * Constraints. `row_count` rows: row `i` sets joint `joints[i]` to `counts[i]`
 * values, taken consecutively from `values` (the layout of `cadaclysm_pose`).
 * False, with `last_error` saying why, when a rule refuses it; the assembly is
 * then unchanged.
 *
 * # Safety
 * `assembly` a live assembly; `name` NUL-terminated UTF-8; `joints` and `counts`
 * each `row_count` entries (each of `joints` NUL-terminated UTF-8); `values` at
 * least the sum of `counts`' entries; `joints`, `counts` and `values` may be null
 * only when `row_count` is 0.
 */
bool cadaclysm_blacksmith_assembly_state(struct CadaclysmBlacksmithAssembly *assembly,
                                         const char *name,
                                         const char *const *joints,
                                         const uint32_t *counts,
                                         const double *values,
                                         size_t row_count);

/**
 * Adds a named motion sequence over the assembly's states: `count` segments, segment
 * `i` reaching state `states[i]` at parameter `ts[i]`, leaving it by
 * `interpolations[i]` (`"undefined"`, `"discontinuous"`, `"synchronous"` or
 * `"linear"`). `seconds` writes the parameter's unit as the second. Closed or open is
 * the last segment's interpolation. False, with the reason at the kernel's last error
 * and the assembly unchanged, on any refusal of the kernel's `Assembly::sequence`.
 *
 * # Safety
 * `assembly` must be a live handle; `name` a valid string; `states` and
 * `interpolations` `count` valid strings each; `ts` `count` doubles.
 */
bool cadaclysm_blacksmith_assembly_sequence(struct CadaclysmBlacksmithAssembly *assembly,
                                            const char *name,
                                            const char *const *states,
                                            const double *ts,
                                            const char *const *interpolations,
                                            size_t count,
                                            bool seconds);

/**
 * Declares `assembly`'s base link -- see `abi::Assembly::base` and the Global
 * Constraints. False, with `last_error` saying why, when a rule refuses it; the
 * assembly is then unchanged.
 *
 * # Safety
 * `assembly` a live assembly; `link` NUL-terminated UTF-8.
 */
bool cadaclysm_blacksmith_assembly_base(struct CadaclysmBlacksmithAssembly *assembly,
                                        const char *link);

/**
 * `assembly` posed: a new assembly, the caller's to free with
 * [`cadaclysm_blacksmith_assembly_free`] -- see `abi::Assembly::posed`. `row_count` rows:
 * row `i` gives joint path `joints[i]` (`/` between names, `\` escaping `/` and `\` in a
 * name) `counts[i]` values, taken consecutively from `values` (the layout of
 * `cadaclysm_blacksmith_assembly_state`). `state` a state's path, or null; `ground` one of
 * `assembly`'s links, or null for its default. Null, with `last_error` saying why, when a
 * rule refuses it; `assembly` is unchanged either way.
 *
 * # Safety
 * `assembly` live; `joints` and `counts` each `row_count` entries (each of `joints`
 * NUL-terminated UTF-8); `values` at least the sum of `counts`; `joints`, `counts` and
 * `values` may be null only when `row_count` is 0; `state` and `ground` null or
 * NUL-terminated UTF-8.
 */
struct CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_posed(const struct CadaclysmBlacksmithAssembly *assembly,
                                                                        const char *const *joints,
                                                                        const uint32_t *counts,
                                                                        const double *values,
                                                                        size_t row_count,
                                                                        const char *state,
                                                                        const char *ground);

/**
 * How many solids are under `assembly`, at any depth: the length of the list
 * [`cadaclysm_blacksmith_assembly_part_path`] reads, and the index the rows of
 * [`cadaclysm_blacksmith_assembly_swept_clash`] use. 0 (and `last_error`) for null.
 *
 * # Safety
 * `assembly` live.
 */
uint32_t cadaclysm_blacksmith_assembly_part_count(const struct CadaclysmBlacksmithAssembly *assembly);

/**
 * The placement path of solid `i` under `assembly` -- depth first, placements in
 * order; names joined by `/`, a `/` or `\` inside a name escaped with `\`, as
 * `cadaclysm_blacksmith_assembly_posed`'s keys are. Owned: free it with
 * [`cadaclysm_blacksmith_string_free`]. Null (and `last_error`) for a null
 * `assembly` or `i` past the last solid.
 *
 * # Safety
 * `assembly` live.
 */
char *cadaclysm_blacksmith_assembly_part_path(const struct CadaclysmBlacksmithAssembly *assembly,
                                              uint32_t i);

/**
 * Every pair of `assembly`'s solids (indexed as
 * [`cadaclysm_blacksmith_assembly_part_path`] lists them) that penetrates, touches or
 * comes within `clearance` anywhere while `assembly`'s own mechanism moves through
 * `key_count` keyframes (at least 2), with the first time it does and the time ranges
 * it stays in clash -- read with the `cadaclysm_blacksmith_swept_clashes_*` calls.
 * Time runs in keyframe units, keyframe `k` at time `k`; between two keyframes each
 * joint value moves linearly, and each link is posed from those values as
 * `cadaclysm_blacksmith_assembly_posed` poses it, so a link swinging about a joint goes
 * round its arc.
 *
 * `joints` names `joint_count` of this assembly's own joints (a key into a
 * sub-assembly is refused), each with `counts[i]` values. `values` is key-major:
 * keyframe 0's values for every joint in order, then keyframe 1's, and so on,
 * `key_count * sum(counts)` doubles. `ground` one of `assembly`'s links, held fixed, or
 * null for its default. Each link is a group; a sub-assembly rides the link its
 * placement is in; solids in no link are one more group, held fixed. Pairs on two
 * links a joint joins are not tested unless `joined`; `allowed` is `allowed_count`
 * pairs of part indices (`2 * allowed_count` numbers, flat) never tested. Parts are
 * meshed at `tolerance`; `resolution` and `max_steps` as
 * `cadaclysm_blacksmith_collider_swept_clash`. Null (and `last_error`) for a null
 * `assembly`, a null `joints`, `counts`, `values` or `allowed` with a count, and in
 * `swept_clash:` words for every refusal of `abi::Assembly::swept_clash`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `assembly` live; `joints` and `counts` each `joint_count` entries (each of `joints`
 * NUL-terminated UTF-8); `values` `key_count * sum(counts)` doubles; `ground` null or
 * NUL-terminated UTF-8; `allowed` null (with `allowed_count` 0) or readable for
 * `2 * allowed_count` entries.
 */
struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_assembly_swept_clash(const struct CadaclysmBlacksmithAssembly *assembly,
                                                                                  const char *const *joints,
                                                                                  const uint32_t *counts,
                                                                                  size_t joint_count,
                                                                                  const double *values,
                                                                                  uint32_t key_count,
                                                                                  const char *ground,
                                                                                  double tolerance,
                                                                                  double clearance,
                                                                                  double resolution,
                                                                                  uint32_t max_steps,
                                                                                  const uint32_t *allowed,
                                                                                  uint32_t allowed_count,
                                                                                  bool joined);

/**
 * How many freedoms a pair kind has, so a caller can size its ranges arrays for
 * [`cadaclysm_blacksmith_assembly_pair`]. 0 for an unknown name, and for
 * `fully_constrained`, which has none.
 *
 * # Safety
 * `kind` null or a NUL-terminated UTF-8 string; null reads as an unknown kind (0).
 */
uint32_t cadaclysm_blacksmith_pair_freedom_count(const char *kind);

/**
 * A flat end mill: Grbl tool `number` (at least 1), `diameter` and
 * `flute_length` in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed.
 * It ramps into its cuts at 3 degrees ([`cadaclysm_blacksmith_tool_with_ramp_angle`]
 * changes that). Null (and `last_error`) for a number of 0 or above 255, or a
 * size, feed or speed not positive and finite.
 */
struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_flat(uint32_t number,
                                                               double diameter,
                                                               double flute_length,
                                                               double feed,
                                                               double plunge,
                                                               double rpm);

/**
 * A ball end mill: as [`cadaclysm_blacksmith_tool_flat`], its tip a half sphere
 * of the diameter.
 */
struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_ball(uint32_t number,
                                                               double diameter,
                                                               double flute_length,
                                                               double feed,
                                                               double plunge,
                                                               double rpm);

/**
 * A drill: as [`cadaclysm_blacksmith_tool_flat`], plunging at `feed`. A drill
 * only drills -- a job refuses it for any other operation.
 */
struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_drill(uint32_t number,
                                                                double diameter,
                                                                double flute_length,
                                                                double feed,
                                                                double rpm);

/**
 * A new tool: `t`, ramping into its cuts at `degrees` from the horizontal. `t` is
 * left as it was. Null (and `last_error`) for a null tool or an angle outside
 * (0, 90].
 *
 * # Safety
 * `t` a live tool.
 */
struct CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_with_ramp_angle(const struct CadaclysmBlacksmithTool *t,
                                                                          double degrees);

/**
 * Release a tool. Null is a no-op. A job it was used in keeps its own copy.
 *
 * # Safety
 * `t` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_tool_free(struct CadaclysmBlacksmithTool *t);

/**
 * The tool's Grbl number, 1 to 255. `UINT32_MAX` (and `last_error`) for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
uint32_t cadaclysm_blacksmith_tool_number(const struct CadaclysmBlacksmithTool *t);

/**
 * The tool's shape: `"flat"`, `"ball"`, `"drill"`, `"vbit"` or `"bullnose"`, a static
 * string the caller never frees. Null (and `last_error`) for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
const char *cadaclysm_blacksmith_tool_shape(const struct CadaclysmBlacksmithTool *t);

/**
 * The tool's cutting diameter, in mm. `NaN` (and `last_error`) for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
double cadaclysm_blacksmith_tool_diameter(const struct CadaclysmBlacksmithTool *t);

/**
 * How far up the tool's cutting edge reaches from the tip, in mm. `NaN` (and
 * `last_error`) for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
double cadaclysm_blacksmith_tool_flute_length(const struct CadaclysmBlacksmithTool *t);

/**
 * A V-bit's included angle, in degrees. `NaN` for every other shape (check
 * [`cadaclysm_blacksmith_tool_shape`] first), and `NaN` with `last_error` for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
double cadaclysm_blacksmith_tool_angle(const struct CadaclysmBlacksmithTool *t);

/**
 * A bull-nose's corner radius, in mm. `NaN` for every other shape (check
 * [`cadaclysm_blacksmith_tool_shape`] first), and `NaN` with `last_error` for null.
 *
 * # Safety
 * `t` a live tool, or null.
 */
double cadaclysm_blacksmith_tool_corner_radius(const struct CadaclysmBlacksmithTool *t);

/**
 * The job's stock box: x, y, z of its lowest corner to `min[0..3]`, of its highest to
 * `max[0..3]` -- what `stock_box` was given, or what `stock_around` worked out.
 * `false` (and `last_error`) for a null job or a null output.
 *
 * # Safety
 * `j` a live job, or null; `min` and `max` three writable doubles each.
 */
bool cadaclysm_blacksmith_job_stock(const struct CadaclysmBlacksmithJob *j,
                                    double *min,
                                    double *max);

/**
 * The box of material from (`min_x`, `min_y`, `min_z`) to (`max_x`, `max_y`,
 * `max_z`). Null (and `last_error`) unless every min is below its max and all six
 * are finite.
 */
struct CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_box(double min_x,
                                                                double min_y,
                                                                double min_z,
                                                                double max_x,
                                                                double max_y,
                                                                double max_z);

/**
 * `s`'s bounding box grown by `margin` sideways and on top (the bottom stays on
 * the part's own). Null (and `last_error`) for a null solid or a margin that is
 * negative or not finite.
 *
 * # Safety
 * `s` a live solid.
 */
struct CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_around(const struct CadaclysmBlacksmithSolid *s,
                                                                   double margin);

/**
 * Release a stock. Null is a no-op. A job made on it keeps its own copy.
 *
 * # Safety
 * `s` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_stock_free(struct CadaclysmBlacksmithStock *s);

/**
 * An empty job on `stock`, rapids at `safe_z` (above the stock's top), named
 * `"job"`, with a clearance of 1, a tolerance of 0.01, a spindle dwell of 2 s
 * and a CAMotics resolution of 0.1 until a `job_set_*` call changes them. Null
 * (and `last_error`) for a null stock or a `safe_z` not above its top.
 *
 * # Safety
 * `stock` a live stock.
 */
struct CadaclysmBlacksmithJob *cadaclysm_blacksmith_job_new(const struct CadaclysmBlacksmithStock *stock,
                                                            double safe_z);

/**
 * How far above an operation's top it enters and leaves its passes. In place;
 * `false` (and `last_error`, the job unchanged) for a null job or a clearance
 * not positive and finite.
 *
 * # Safety
 * `j` a live job no other thread is using.
 */
bool cadaclysm_blacksmith_job_set_clearance(struct CadaclysmBlacksmithJob *j, double clearance);

/**
 * The tolerance free-form sides are fitted and offsets computed to. In place;
 * `false` (and `last_error`, the job unchanged) for a null job or a tolerance
 * not positive and finite.
 *
 * # Safety
 * `j` a live job no other thread is using.
 */
bool cadaclysm_blacksmith_job_set_tolerance(struct CadaclysmBlacksmithJob *j, double tolerance);

/**
 * The seconds every program waits (`G4`) after starting the spindle; 0 writes no
 * wait. In place; `false` (and `last_error`, the job unchanged) for a null job
 * or a dwell negative or not finite.
 *
 * # Safety
 * `j` a live job no other thread is using.
 */
bool cadaclysm_blacksmith_job_set_spindle_dwell(struct CadaclysmBlacksmithJob *j, double seconds);

/**
 * The name programs are called after (`<name>-T<n>`) and written into their
 * header comment. In place; `false` (and `last_error`, the job unchanged) for a
 * null job, a null or non-UTF-8 name, or a name the job refuses.
 *
 * # Safety
 * `j` a live job no other thread is using; `name` NUL-terminated.
 */
bool cadaclysm_blacksmith_job_set_name(struct CadaclysmBlacksmithJob *j, const char *name);

/**
 * The voxel size, in mm, of the CAMotics project [`cadaclysm_blacksmith_job_camotics`]
 * writes. In place; `false` (and `last_error`, the job unchanged) for a null job
 * or a resolution not positive and finite.
 *
 * # Safety
 * `j` a live job no other thread is using.
 */
bool cadaclysm_blacksmith_job_set_resolution(struct CadaclysmBlacksmithJob *j, double resolution);

/**
 * Face the stock's top down to `z`, in rows `stepover` apart and passes at most
 * `stepdown` deep, with `t`. Added to the job in place; `false` (and
 * `last_error`, the job unchanged) for a null job or tool, or what the job
 * refuses (a drill, a `z` above the top, a stepover past the diameter, ...).
 *
 * # Safety
 * `j` a live job no other thread is using; `t` a live tool.
 */
bool cadaclysm_blacksmith_job_face(struct CadaclysmBlacksmithJob *j,
                                   const struct CadaclysmBlacksmithTool *t,
                                   double z,
                                   double stepover,
                                   double stepdown);

/**
 * Cut along `p` from `top` to `bottom` in passes at most `stepdown` deep, with
 * `t`: `side` 0 outside the profile, 1 inside it, 2 on its line; `climb` for
 * climb milling, else conventional; `open` to cut the outline as an open chain
 * (only on its line, and with no holes). Added in place; `false` (and
 * `last_error`, the job unchanged) for a null job, tool or profile, a `side` past
 * 2, or what the job refuses.
 *
 * # Safety
 * `j` a live job no other thread is using; `t` a live tool; `p` a live profile.
 */
bool cadaclysm_blacksmith_job_contour(struct CadaclysmBlacksmithJob *j,
                                      const struct CadaclysmBlacksmithTool *t,
                                      const struct CadaclysmBlacksmithProfile *p,
                                      double top,
                                      double bottom,
                                      uint32_t side,
                                      double stepdown,
                                      bool climb,
                                      bool open);

/**
 * Clear `p` -- its holes left standing as islands -- from `top` to `bottom`, in
 * rings `stepover` apart (at most the tool's radius) and passes at most
 * `stepdown` deep, with `t`. Added in place; `false` (and `last_error`, the job
 * unchanged) for a null job, tool or profile, or what the job refuses.
 *
 * # Safety
 * `j` a live job no other thread is using; `t` a live tool; `p` a live profile.
 */
bool cadaclysm_blacksmith_job_pocket(struct CadaclysmBlacksmithJob *j,
                                     const struct CadaclysmBlacksmithTool *t,
                                     const struct CadaclysmBlacksmithProfile *p,
                                     double top,
                                     double bottom,
                                     double stepover,
                                     double stepdown);

/**
 * Drill `count` holes at `xy` (x0, y0, x1, y1, ... -- `2 * count` doubles) from
 * `top` to `bottom` with `t`, pecking `peck` deep at a time, or straight to depth
 * when `peck` is NaN. Added in place; `false` (and `last_error`, the job
 * unchanged) for a null job or tool, a null `xy` with a `count` above 0, or what
 * the job refuses.
 *
 * # Safety
 * `j` a live job no other thread is using; `t` a live tool; `xy` readable for
 * `2 * count` doubles, or null when `count` is 0.
 */
bool cadaclysm_blacksmith_job_drill(struct CadaclysmBlacksmithJob *j,
                                    const struct CadaclysmBlacksmithTool *t,
                                    const double *xy,
                                    size_t count,
                                    double top,
                                    double bottom,
                                    double peck);

/**
 * The job as Grbl 1.1 programs, one per run of consecutive operations sharing a
 * tool, each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k` of a tool that
 * runs more than once). Null (and `last_error`) for a null job or a toolpath the
 * writer refuses; a list of count 0 for a job with no operations.
 *
 * # Safety
 * `j` a live job no other thread is changing.
 */
struct CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_gcode(const struct CadaclysmBlacksmithJob *j);

/**
 * Every file of a CAMotics project named `stem`, in memory and in the order it
 * would be written: each program (`<stem>-T<n>.nc`, or `<stem>-<k>-T<n>.nc` for
 * run `k` of a repeated tool), its simulation copy, and the project
 * (`<stem>.camotics`, tool 0) last. Each entry's name is the file's name, its
 * text the file's content. Null (and `last_error`) for a null job, a null or
 * non-UTF-8 stem, a stem that is not a plain file name, or what `job_gcode`
 * refuses.
 *
 * # Safety
 * `j` a live job no other thread is changing; `stem` NUL-terminated.
 */
struct CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_camotics(const struct CadaclysmBlacksmithJob *j,
                                                                      const char *stem);

/**
 * Release a job. Null is a no-op. Lists it wrote are independent and outlive it.
 *
 * # Safety
 * `j` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_job_free(struct CadaclysmBlacksmithJob *j);

/**
 * How many files. `UINT32_MAX` (and `last_error`) for null.
 *
 * # Safety
 * `l` a live list.
 */
uint32_t cadaclysm_blacksmith_programs_count(const struct CadaclysmBlacksmithPrograms *l);

/**
 * File `i`'s Grbl tool number; 0 for a CAMotics project file. `UINT32_MAX` (and
 * `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `l` a live list.
 */
uint32_t cadaclysm_blacksmith_programs_tool(const struct CadaclysmBlacksmithPrograms *l,
                                            uint32_t i);

/**
 * File `i`'s name: for [`cadaclysm_blacksmith_job_gcode`], the program's name
 * without extension (`<name>-T<n>`, or `<name>-<k>-T<n>` for a repeated tool);
 * for [`cadaclysm_blacksmith_job_camotics`], the file's name. Owned by the list
 * and good until [`cadaclysm_blacksmith_programs_free`]; never freed by the
 * caller. Null (and `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `l` a live list.
 */
const char *cadaclysm_blacksmith_programs_name(const struct CadaclysmBlacksmithPrograms *l,
                                               uint32_t i);

/**
 * File `i`'s content: G-code, or a CAMotics project's JSON. Owned by the list and
 * good until [`cadaclysm_blacksmith_programs_free`]; never freed by the caller.
 * Null (and `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `l` a live list.
 */
const char *cadaclysm_blacksmith_programs_text(const struct CadaclysmBlacksmithPrograms *l,
                                               uint32_t i);

/**
 * Release a list, and every string read out of it. Null is a no-op.
 *
 * # Safety
 * `l` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_programs_free(struct CadaclysmBlacksmithPrograms *l);

/**
 * Recognise `part` and append the operations that make it to `j`: `NaN`
 * `stepover`/`stepdown`/`peck` are the kernel's own defaults; `skin` is always
 * given. `drills` is `drill_count` tool pointers, or null when `drill_count` is
 * 0. `j` changes only on success -- a refusal leaves it exactly as it was. Null
 * (and `last_error`) for a null job, part or end mill, a null drill pointer at
 * index `i` (named `"job_machine: null drill <i>"`), or what the kernel
 * refuses (a drill as the end mill, ...).
 *
 * # Safety
 * `j` a live job no other thread is using; `part` a live solid; `end_mill` a
 * live tool; `drills` readable for `drill_count` tool pointers (each null or a
 * live tool), or null when `drill_count` is 0.
 */
struct CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine(struct CadaclysmBlacksmithJob *j,
                                                                   const struct CadaclysmBlacksmithSolid *part,
                                                                   const struct CadaclysmBlacksmithTool *end_mill,
                                                                   const struct CadaclysmBlacksmithTool *const *drills,
                                                                   size_t drill_count,
                                                                   double stepover,
                                                                   double stepdown,
                                                                   double skin,
                                                                   double peck);

/**
 * [`cadaclysm_blacksmith_job_machine`] with several end mills, largest first: each
 * later one cleans what the earlier ones left -- inside corners, regions too narrow
 * for them, holes no drill matches. `end_mills` is `end_mill_count` tool pointers;
 * `drills` as in `job_machine`. `j` changes only on success. Null (and `last_error`)
 * for a null job or part, a null `end_mills` with a count above 0, a null end mill at
 * index `i` (named `"job_machine_with: null end mill <i>"`), a null drill (as
 * `job_machine`, named `"job_machine_with: null drill <i>"`), or what the kernel
 * refuses (no end mill, one not smaller than the one before, two sharing a number, a
 * drill, V-bit or bull-nose among them, ...).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_job_machine`]; `end_mills` readable for
 * `end_mill_count` tool pointers (each null or a live tool), or null when
 * `end_mill_count` is 0.
 */
struct CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine_with(struct CadaclysmBlacksmithJob *j,
                                                                        const struct CadaclysmBlacksmithSolid *part,
                                                                        const struct CadaclysmBlacksmithTool *const *end_mills,
                                                                        size_t end_mill_count,
                                                                        const struct CadaclysmBlacksmithTool *const *drills,
                                                                        size_t drill_count,
                                                                        double stepover,
                                                                        double stepdown,
                                                                        double skin,
                                                                        double peck);

/**
 * How many items. `UINT32_MAX` (and `last_error`) for null.
 *
 * # Safety
 * `r` a live report.
 */
uint32_t cadaclysm_blacksmith_report_count(const struct CadaclysmBlacksmithReport *r);

/**
 * Item `i`'s kind: `"corner"`, `"hole"`, `"slope"`, `"undercut"` or
 * `"too_deep"`. Owned by the report and good until
 * [`cadaclysm_blacksmith_report_free`]; never freed by the caller. Null (and
 * `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `r` a live report.
 */
const char *cadaclysm_blacksmith_report_kind(const struct CadaclysmBlacksmithReport *r, uint32_t i);

/**
 * Item `i`'s location: x, y, z written to `out[0..3]`. `false` (and
 * `last_error`) for null, `i` out of range, or a null `out`.
 *
 * # Safety
 * `r` a live report; `out` three writable doubles.
 */
bool cadaclysm_blacksmith_report_at(const struct CadaclysmBlacksmithReport *r,
                                    uint32_t i,
                                    double *out);

/**
 * Item `i`'s size, per kind. `NaN` (and `last_error`) for null or `i` out of
 * range -- unambiguous, since a size is never `NaN`.
 *
 * # Safety
 * `r` a live report.
 */
double cadaclysm_blacksmith_report_size(const struct CadaclysmBlacksmithReport *r, uint32_t i);

/**
 * Item `i`'s top: the highest Z it stands at. `NaN` (and `last_error`) for null or
 * `i` out of range.
 *
 * # Safety
 * `r` a live report.
 */
double cadaclysm_blacksmith_report_top(const struct CadaclysmBlacksmithReport *r, uint32_t i);

/**
 * Item `i`'s bottom: the lowest Z it stands down to. `NaN` (and `last_error`) for
 * null or `i` out of range.
 *
 * # Safety
 * `r` a live report.
 */
double cadaclysm_blacksmith_report_bottom(const struct CadaclysmBlacksmithReport *r, uint32_t i);

/**
 * Item `i`'s reason, in one sentence naming the tool involved. Owned by the
 * report and good until [`cadaclysm_blacksmith_report_free`]; never freed by
 * the caller. Null (and `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `r` a live report.
 */
const char *cadaclysm_blacksmith_report_reason(const struct CadaclysmBlacksmithReport *r,
                                               uint32_t i);

/**
 * Item `i`'s XY area, as a new profile list the caller frees with
 * [`cadaclysm_blacksmith_profile_list_free`]. Null (and `last_error`) for null
 * or `i` out of range.
 *
 * # Safety
 * `r` a live report.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_report_region(const struct CadaclysmBlacksmithReport *r,
                                                                          uint32_t i);

/**
 * The report's own `Display`: one line per item, or `"nothing left uncut"`.
 * Owned by the report and good until [`cadaclysm_blacksmith_report_free`];
 * never freed by the caller. Null (and `last_error`) for null.
 *
 * # Safety
 * `r` a live report.
 */
const char *cadaclysm_blacksmith_report_text(const struct CadaclysmBlacksmithReport *r);

/**
 * Release a report, and every string read out of it. Null is a no-op.
 *
 * # Safety
 * `r` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_report_free(struct CadaclysmBlacksmithReport *r);

/**
 * Every operation added to `j` so far, in order. Null (and `last_error`) for a
 * null job.
 *
 * # Safety
 * `j` a live job no other thread is changing.
 */
struct CadaclysmBlacksmithOperations *cadaclysm_blacksmith_job_operations(const struct CadaclysmBlacksmithJob *j);

/**
 * How many operations. `UINT32_MAX` (and `last_error`) for null.
 *
 * # Safety
 * `l` a live list.
 */
uint32_t cadaclysm_blacksmith_operations_count(const struct CadaclysmBlacksmithOperations *l);

/**
 * Operation `i`'s kind: `"face"`, `"contour"`, `"pocket"` or `"drill"`. Owned
 * by the list and good until [`cadaclysm_blacksmith_operations_free`]; never
 * freed by the caller. Null (and `last_error`) for null or `i` out of range.
 *
 * # Safety
 * `l` a live list.
 */
const char *cadaclysm_blacksmith_operations_kind(const struct CadaclysmBlacksmithOperations *l,
                                                 uint32_t i);

/**
 * Operation `i`'s tool number. `UINT32_MAX` (and `last_error`) for null or `i`
 * out of range.
 *
 * # Safety
 * `l` a live list.
 */
uint32_t cadaclysm_blacksmith_operations_tool(const struct CadaclysmBlacksmithOperations *l,
                                              uint32_t i);

/**
 * How many params operation `i` has. `UINT32_MAX` (and `last_error`) for null
 * or `i` out of range.
 *
 * # Safety
 * `l` a live list.
 */
uint32_t cadaclysm_blacksmith_operations_param_count(const struct CadaclysmBlacksmithOperations *l,
                                                     uint32_t i);

/**
 * Operation `i`'s param `k`'s name. Owned by the list and good until
 * [`cadaclysm_blacksmith_operations_free`]; never freed by the caller. Null
 * (and `last_error`) for null, `i` out of range, or `k` out of range -- a
 * caller checks [`cadaclysm_blacksmith_operations_param_count`] first.
 *
 * # Safety
 * `l` a live list.
 */
const char *cadaclysm_blacksmith_operations_param_name(const struct CadaclysmBlacksmithOperations *l,
                                                       uint32_t i,
                                                       uint32_t k);

/**
 * Operation `i`'s param `k`'s value. May legitimately be `NaN` (a drill's
 * `peck` when there is none); on a bad index it is also `NaN`, with
 * `last_error` set -- a caller checks
 * [`cadaclysm_blacksmith_operations_param_count`] first, since `NaN` alone
 * does not say which happened.
 *
 * # Safety
 * `l` a live list.
 */
double cadaclysm_blacksmith_operations_param_value(const struct CadaclysmBlacksmithOperations *l,
                                                   uint32_t i,
                                                   uint32_t k);

/**
 * Release a list, and every string read out of it. Null is a no-op.
 *
 * # Safety
 * `l` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_operations_free(struct CadaclysmBlacksmithOperations *l);

/**
 * Every pair of `collider`'s parts that penetrates, touches or lies within
 * `clearance` of the other with each group placed at its frame in `frames`
 * (12 doubles a frame, `frame_count` of them, in group order), in pair order.
 * `clearance` is zero or more; a pair farther apart than the collider's
 * tolerance but within it is `"too_close"`, within the tolerance `"touching"`.
 * `share_n` 0: every pair is decided now; otherwise only those whose index is
 * `share_k` modulo `share_n`. Frames are read as
 * `cadaclysm_blacksmith_collider_check` reads them (a float32 pose within 1e-6
 * of rigid is squared up). Null (and `last_error`) for a null `collider`, a
 * null `frames` with a `frame_count`, `frame_count` not the collider's group
 * count, a bad frame, `share_k >= share_n` when `share_n` is not 0, or a
 * `clearance` that is negative or not finite. The collider keeps each measured
 * part's closest mesh for its lifetime.
 *
 * # Safety
 * `collider` live; `frames` readable for `12 * frame_count` doubles. Safe from
 * several threads on one collider, which serialize as `collider_check` does.
 */
struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_collider_clash(struct CadaclysmBlacksmithCollider *collider,
                                                                       const double *frames,
                                                                       uint32_t frame_count,
                                                                       double clearance,
                                                                       uint32_t share_k,
                                                                       uint32_t share_n);

/**
 * The pairs of solids that penetrate, touch or lie within `clearance` of one
 * another, at rest, meshed at `tolerance` (positive and finite, or unset): `a`
 * (`a_count` solids) against itself when `b` is null with `b_count` 0, else
 * against `b` (`b_count` solids; only pairs across the two, and a row's `b`
 * indexes `b`). `allowed` is `allowed_count` pairs of indices (`2 *
 * allowed_count` numbers, flat; an `a` index then a `b` index for two sets)
 * never tested -- designed contacts. Null (and `last_error`) for a null `a` or
 * `b` with a count, a null solid in either, an empty set, an `allowed` pair out
 * of range, a part that is not a closed solid, a bad tolerance, or a
 * `clearance` that is negative or not finite.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a` and `b` readable for their counts, each entry null or a live solid;
 * `allowed` null (with `allowed_count` 0) or readable for `2 * allowed_count`
 * entries.
 */
struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_clash(const struct CadaclysmBlacksmithSolid *const *a,
                                                              uint32_t a_count,
                                                              const struct CadaclysmBlacksmithSolid *const *b,
                                                              uint32_t b_count,
                                                              double tolerance,
                                                              double clearance,
                                                              const uint32_t *allowed,
                                                              uint32_t allowed_count);

/**
 * Release a clashes handle. Null is a no-op.
 *
 * # Safety
 * `clashes` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_clashes_free(struct CadaclysmBlacksmithClashes *clashes);

/**
 * How many pairs. 0 (and `last_error`) for null.
 *
 * # Safety
 * `clashes` live.
 */
uint32_t cadaclysm_blacksmith_clashes_count(const struct CadaclysmBlacksmithClashes *clashes);

/**
 * Pair `i` into `out`; its strings borrow from the handle. `false` (and
 * `last_error`) for null `clashes`, a null `out`, or `i` out of range; `out`
 * is untouched then.
 *
 * # Safety
 * `clashes` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_clashes_at(const struct CadaclysmBlacksmithClashes *clashes,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithClash *out);

/**
 * The volume pair `i`'s two parts share, at the frames it was found at, as a
 * new solid. Null (and `last_error`) for a null `clashes`, `i` out of range, or
 * a pair that is not `"penetrating"`.
 *
 * # Safety
 * `clashes` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_clashes_solid(const struct CadaclysmBlacksmithClashes *clashes,
                                                                    uint32_t i);

/**
 * Where pair `i`'s two parts cross or coincide, at the frames it was found at
 * and the list's tolerance: the chains and overlap regions
 * `cadaclysm_blacksmith_intersect` reports, read with the
 * `cadaclysm_blacksmith_intersection_*` calls and freed with
 * `cadaclysm_blacksmith_intersection_free`. Any pair but a refused one has one
 * (a touching pair of boxes face to face has the shared face as an overlap
 * region). Null (and `last_error`) for a null `clashes`, `i` out of range, or a
 * refused pair.
 *
 * # Safety
 * `clashes` live.
 */
struct CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_clashes_intersect(const struct CadaclysmBlacksmithClashes *clashes,
                                                                               uint32_t i);

/**
 * Every pair of `collider`'s parts that penetrates, touches or comes within
 * `clearance` anywhere on the path through `poses`, with the first time it
 * does and the time ranges it stays in clash, in pair order. `poses` is
 * `pose_count` poses (at least 2) of `frame_count` frames each (one per group,
 * in group order), 12 doubles a frame, read as
 * `cadaclysm_blacksmith_collider_check` reads them. `resolution` (in `(0, 1]`,
 * a fraction of a segment; 1e-3 is the usual) is how closely an interval's end
 * is found; `max_steps` (at least 1; 100000 is the usual) the pose-wise tests
 * one pair may take -- a pair that needs more is a refused row. `share_n` 0:
 * every pair; otherwise only the pairs whose swept boxes meet numbered
 * `share_k` modulo `share_n`. Null (and `last_error`) for a null `collider`, a
 * null `poses` with a count, fewer than 2 poses, `frame_count` not the
 * collider's group count, a bad frame, a `clearance` that is negative or not
 * finite, a `resolution` outside `(0, 1]`, `max_steps` 0, or `share_k >=
 * share_n` when `share_n` is not 0. The collider's pose caches are neither read
 * nor filled.
 *
 * # Safety
 * `collider` live; `poses` readable for `12 * pose_count * frame_count`
 * doubles. Safe from several threads on one collider, which serialize as
 * `collider_check` does.
 */
struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_collider_swept_clash(struct CadaclysmBlacksmithCollider *collider,
                                                                                  const double *poses,
                                                                                  uint32_t pose_count,
                                                                                  uint32_t frame_count,
                                                                                  double clearance,
                                                                                  double resolution,
                                                                                  uint32_t max_steps,
                                                                                  uint32_t share_k,
                                                                                  uint32_t share_n);

/**
 * The pairs of solids that penetrate, touch or come within `clearance` of one
 * another anywhere on a path of `pose_count` poses (at least 2), meshed at
 * `tolerance` (positive and finite, or unset), each part its own group: `a` (`a_count`
 * solids) against itself when `b` is null with `b_count` 0, else against `b`
 * (`b_count` solids; only pairs across the two, and a row's `b` indexes `b`).
 * `poses_a` is `pose_count` poses of `a_count` frames (12 doubles a frame,
 * pose by pose), placing `a`'s parts; `poses_b` likewise `pose_count` poses of
 * `b_count` frames, null with `b`. `allowed` is `allowed_count` pairs of
 * indices (`2 * allowed_count` numbers, flat; an `a` index then a `b` index for
 * two sets) never tested. `resolution` and `max_steps` as
 * `cadaclysm_blacksmith_collider_swept_clash`. Null (and `last_error`) for a
 * null `a`, `b`, `poses_a`, `poses_b` or `allowed` with a count, a null solid
 * in either set, an empty set, fewer than 2 poses, an `allowed` pair out of
 * range, a part that is not a closed solid, a bad frame, tolerance,
 * clearance or resolution, or `max_steps` 0.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a` and `b` readable for their counts, each entry null or a live solid;
 * `poses_a` readable for `12 * pose_count * a_count` doubles, `poses_b` for
 * `12 * pose_count * b_count`; `allowed` null (with `allowed_count` 0) or
 * readable for `2 * allowed_count` entries.
 */
struct CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_swept_clash(const struct CadaclysmBlacksmithSolid *const *a,
                                                                         uint32_t a_count,
                                                                         const double *poses_a,
                                                                         const struct CadaclysmBlacksmithSolid *const *b,
                                                                         uint32_t b_count,
                                                                         const double *poses_b,
                                                                         uint32_t pose_count,
                                                                         double tolerance,
                                                                         double clearance,
                                                                         double resolution,
                                                                         uint32_t max_steps,
                                                                         const uint32_t *allowed,
                                                                         uint32_t allowed_count);

/**
 * Release a swept clashes handle. Null is a no-op.
 *
 * # Safety
 * `swept` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_swept_clashes_free(struct CadaclysmBlacksmithSweptClashes *swept);

/**
 * How many pairs. 0 (and `last_error`) for null.
 *
 * # Safety
 * `swept` live.
 */
uint32_t cadaclysm_blacksmith_swept_clashes_count(const struct CadaclysmBlacksmithSweptClashes *swept);

/**
 * Pair `i` into `out`. `false` (and `last_error`) for null `swept`, a null
 * `out`, or `i` out of range; `out` is untouched then.
 *
 * # Safety
 * `swept` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_swept_clashes_at(const struct CadaclysmBlacksmithSweptClashes *swept,
                                           uint32_t i,
                                           struct CadaclysmBlacksmithSweptClash *out);

/**
 * Interval `k` of pair `i` into `out[0]` (its start) and `out[1]` (its end),
 * in pose units. `false` (and `last_error`) for null `swept`, a null `out`, `i`
 * or `k` out of range; `out` is untouched then.
 *
 * # Safety
 * `swept` live; `out` writable for 2 doubles.
 */
bool cadaclysm_blacksmith_swept_clashes_interval(const struct CadaclysmBlacksmithSweptClashes *swept,
                                                 uint32_t i,
                                                 uint32_t k,
                                                 double *out);

/**
 * The first rows as a new clashes list, one row per pair in the same order:
 * row `i` is pair `i`'s pose-wise clash at its first time (kind, distance,
 * points, features, depth, text), at the frames the motion places the parts
 * there, so `cadaclysm_blacksmith_clashes_solid` and
 * `cadaclysm_blacksmith_clashes_intersect` rebuild the contact at that time.
 * Every `cadaclysm_blacksmith_clashes_*` call works on it; free it with
 * `cadaclysm_blacksmith_clashes_free`, independently of `swept`. Null (and
 * `last_error`) for null `swept`.
 *
 * # Safety
 * `swept` live.
 */
struct CadaclysmBlacksmithClashes *cadaclysm_blacksmith_swept_clashes_firsts(const struct CadaclysmBlacksmithSweptClashes *swept);

/**
 * A classifier for the closed `solid` at the absolute `tolerance` (positive and finite, or
 * unset). Null (and `last_error`) for a null `solid`, a tolerance that is negative or
 * infinite, an open body (its inside means nothing) or a body that meshes to nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithClassifier *cadaclysm_blacksmith_classifier_new(const struct CadaclysmBlacksmithSolid *solid,
                                                                          double tolerance);

/**
 * Where `point` (3 doubles) is relative to the classifier's body, into `out`: one of the
 * `CADACLYSM_BLACKSMITH_OUTSIDE`/`_INSIDE`/`_ON` codes. `false` (and `last_error`) for a null
 * `classifier`, `point` or `out`, or a point that is not finite; `out` is untouched then.
 *
 * # Safety
 * `classifier` null or live; `point` null or readable for 3 doubles; `out` null or valid. The
 * handle wraps the kernel's classifier in a mutex, so calling this from several threads at once
 * on the same classifier is safe -- the calls serialise, one point at a time, rather than run in
 * parallel. Build one classifier per thread to classify in parallel.
 */
bool cadaclysm_blacksmith_classifier_contains(const struct CadaclysmBlacksmithClassifier *classifier,
                                              const double *point,
                                              uint32_t *out);

/**
 * Release a classifier. Null is a no-op.
 *
 * # Safety
 * `classifier` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_classifier_free(struct CadaclysmBlacksmithClassifier *classifier);

/**
 * Where `point` (3 doubles) is relative to the closed `solid`, to the absolute `tolerance`
 * (positive and finite, or unset), into `out` -- a classifier built and asked once, so the body is meshed
 * every call: build a [`CadaclysmBlacksmithClassifier`] for more than a few points. `false`
 * (and `last_error`) for a null `solid`, `point` or `out`, a point that is not finite, or what
 * [`cadaclysm_blacksmith_classifier_new`] refuses.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live; `point` null or readable for 3 doubles; `out` null or valid.
 */
bool cadaclysm_blacksmith_contains(const struct CadaclysmBlacksmithSolid *solid,
                                   const double *point,
                                   double tolerance,
                                   uint32_t *out);

/**
 * `solid`'s box at `tolerance`: its boolean mesh, padded by twice that.
 * `false` (and `last_error`) for a null `solid`, a null `out`, a `tolerance`
 * negative or infinite, or a solid that meshes to nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_solid_bounds_box(const struct CadaclysmBlacksmithSolid *solid,
                                           double tolerance,
                                           struct CadaclysmBlacksmithBox *out);

/**
 * `box` moved by `frame` (12 doubles: origin, x, y, z), boxed again on the
 * world axes. `false` (and `last_error`) for a null `box`, a null `frame`, a
 * null `out`, or a `frame` that is not 12 finite numbers or not rigid.
 *
 * # Safety
 * `box_`, `frame` and `out` valid as described.
 */
bool cadaclysm_blacksmith_box_moved(const struct CadaclysmBlacksmithBox *box_,
                                    const double *frame,
                                    struct CadaclysmBlacksmithBox *out);

/**
 * Whether the two boxes share a point (touching counts). `false` for a null
 * `a` or `b` too (with `last_error` set), not just for boxes that do not
 * overlap -- check `last_error` to tell the two apart.
 *
 * # Safety
 * `a` and `b` valid boxes.
 */
bool cadaclysm_blacksmith_box_overlaps(const struct CadaclysmBlacksmithBox *a,
                                       const struct CadaclysmBlacksmithBox *b);

/**
 * True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch --
 * a separating axis among the boxes' face normals and edge-direction crosses;
 * touching is not apart. `false` (and `last_error`) for a null `a`, `b`,
 * `frame_a`, `frame_b` or `apart`, or a frame that is not 12 finite numbers or
 * not rigid.
 *
 * # Safety
 * `a`, `frame_a`, `b`, `frame_b` and `apart` valid as described.
 */
bool cadaclysm_blacksmith_boxes_apart(const struct CadaclysmBlacksmithBox *a,
                                      const double *frame_a,
                                      const struct CadaclysmBlacksmithBox *b,
                                      const double *frame_b,
                                      bool *apart);

/**
 * `solids`, `count` of them, at rest, meshed at `tolerance`; `groups`
 * (`count` entries, or null for each part its own group); `allowed` (`2 *
 * allowed_count` part indices, pairs never tested -- designed contacts).
 * Null (and `last_error`) for a null `solids`, a null entry in it, `count`
 * zero, or the kernel's own refusal (a tolerance negative or infinite,
 * `groups` the wrong length, an `allowed` pair out of range, or a part that
 * is not a closed solid).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solids` readable for `count` entries, each null or a live solid; `groups`
 * null or readable for `count` entries; `allowed` null (with `allowed_count`
 * 0) or readable for `2 * allowed_count` entries.
 */
struct CadaclysmBlacksmithCollider *cadaclysm_blacksmith_collider_new(const struct CadaclysmBlacksmithSolid *const *solids,
                                                                      uint32_t count,
                                                                      double tolerance,
                                                                      const uint32_t *groups,
                                                                      const uint32_t *allowed,
                                                                      uint32_t allowed_count);

/**
 * Release a collider. Null is a no-op.
 *
 * # Safety
 * `collider` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_collider_free(struct CadaclysmBlacksmithCollider *collider);

/**
 * How many groups `collider` has. 0 (and `last_error`) for null.
 *
 * # Safety
 * `collider` live.
 */
uint32_t cadaclysm_blacksmith_collider_group_count(const struct CadaclysmBlacksmithCollider *collider);

/**
 * Counts of the last [`cadaclysm_blacksmith_collider_check`] (all zero before
 * the first call, and for a null `collider` or `out`).
 *
 * # Safety
 * `collider` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_collider_stats(const struct CadaclysmBlacksmithCollider *collider,
                                         struct CadaclysmBlacksmithColliderStats *out);

/**
 * The pairs that interfere, or could not be decided, with each group placed
 * at its frame in `frames` (12 doubles a frame, `frame_count` of them, in
 * group order). `share_n` 0: every pair past the box filters is decided now;
 * otherwise only those whose index is `share_k` modulo `share_n` (the shares
 * of one pose are disjoint and cover it). Null (and `last_error`) for a null
 * `collider`, a null `frames`, `frame_count` not the collider's own group
 * count, a frame that is not 12 finite numbers or not rigid, or `share_k >=
 * share_n` when `share_n` is not 0. A frame whose axes are within 1e-6 of
 * unit length and of square (a float32 pose) is squared up first
 * (Gram-Schmidt: x normalised, y made square to x, z = x cross y, keeping
 * its handedness); one further off, or mirrored, is refused.
 *
 * # Safety
 * `collider` live; `frames` readable for `12 * frame_count` doubles. The
 * handle wraps the kernel's own collider in a mutex, so calling this from
 * several threads at once on the same collider is safe -- the calls just
 * serialize, one `check` at a time, rather than run in parallel.
 */
struct CadaclysmBlacksmithCollisions *cadaclysm_blacksmith_collider_check(struct CadaclysmBlacksmithCollider *collider,
                                                                          const double *frames,
                                                                          uint32_t frame_count,
                                                                          uint32_t share_k,
                                                                          uint32_t share_n);

/**
 * Release a collisions handle. Null is a no-op.
 *
 * # Safety
 * `collisions` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_collisions_free(struct CadaclysmBlacksmithCollisions *collisions);

/**
 * How many collisions. 0 (and `last_error`) for null.
 *
 * # Safety
 * `collisions` live.
 */
uint32_t cadaclysm_blacksmith_collisions_count(const struct CadaclysmBlacksmithCollisions *collisions);

/**
 * Collision `i` into `out`. `false` (and `last_error`) for null `collisions`,
 * a null `out`, or `i` out of range.
 *
 * # Safety
 * `collisions` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_collisions_hit(const struct CadaclysmBlacksmithCollisions *collisions,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithCollisionHit *out);

/**
 * The exact overlap of collision `i`'s two parts at the frames it was found
 * at, as a new solid. Null (and `last_error`) for a null `collisions`, `i`
 * out of range, or a collision that was refused (not an overlap).
 *
 * # Safety
 * `collisions` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_collisions_solid(const struct CadaclysmBlacksmithCollisions *collisions,
                                                                       uint32_t i);

/**
 * A new, empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`; null or
 * empty is `mm`). Free it with [`cadaclysm_blacksmith_document_free`].
 *
 * # Safety
 * `units` null or a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_new(const char *units);

/**
 * A document read from `text`, as [`cadaclysm_blacksmith_document_save`] writes it: its nodes,
 * parameters, history and branches. Null and `last_error` for text that is not a document.
 *
 * # Safety
 * `text` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_load(const char *text);

/**
 * The document as canonical JSON text. Owned: release it with [`cadaclysm_blacksmith_string_free`].
 * An open batch or preview is not in it.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_save(const struct CadaclysmBlacksmithDocument *doc);

/**
 * Applies one op (`op`, JSON: `{"op": "add", "node": {...}}` and the rest) and records it as one
 * commit, with `message` (null or empty: none). The changed set as JSON,
 * `{"added": [ids], "changed": [ids], "removed": [ids], "params": [names]}`: owned, release it
 * with [`cadaclysm_blacksmith_string_free`]. Null and `last_error` (the reason) when the op is
 * refused; the document is unchanged.
 *
 * # Safety
 * `doc` a live document; `op` a NUL-terminated UTF-8 string; `message` null or the same.
 */
char *cadaclysm_blacksmith_document_apply(struct CadaclysmBlacksmithDocument *doc,
                                          const char *op,
                                          const char *message);

/**
 * One drag frame: applies `op` without recording it, after taking back the last frame. The
 * changed set, relative to the state before the preview, as [`cadaclysm_blacksmith_document_apply`].
 * Owned. Null and `last_error` when refused.
 *
 * # Safety
 * `doc` a live document; `op` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_preview(struct CadaclysmBlacksmithDocument *doc,
                                            const char *op);

/**
 * Opens a preview that lasts until [`cadaclysm_blacksmith_document_end_preview`]: later applies
 * are previewed, never recorded. False and `last_error` while a batch or a preview is open.
 *
 * # Safety
 * `doc` a live document.
 */
bool cadaclysm_blacksmith_document_preview_begin(struct CadaclysmBlacksmithDocument *doc);

/**
 * Takes back an open preview; the changed set of doing so. Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_end_preview(struct CadaclysmBlacksmithDocument *doc);

/**
 * Opens a batch: later applies are applied live and recorded as one commit by
 * [`cadaclysm_blacksmith_document_batch_end`], with `message` (null or empty: none). False and
 * `last_error` while a batch or a preview is open.
 *
 * # Safety
 * `doc` a live document; `message` null or a NUL-terminated UTF-8 string.
 */
bool cadaclysm_blacksmith_document_batch_begin(struct CadaclysmBlacksmithDocument *doc,
                                               const char *message);

/**
 * Records the open batch as one commit (nothing if it holds no ops); the changed set, owned.
 * Null and `last_error` when no batch is open.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_batch_end(struct CadaclysmBlacksmithDocument *doc);

/**
 * Reverts every op of the open batch; the changed set, owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_batch_abort(struct CadaclysmBlacksmithDocument *doc);

/**
 * Takes back the head commit. The changed set as JSON, owned; the text `null` when there was
 * nothing to undo. Null pointer and `last_error` for a real refusal (a batch or a preview is open).
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_undo(struct CadaclysmBlacksmithDocument *doc);

/**
 * Puts back the commit [`cadaclysm_blacksmith_document_undo`] took back, as it does: the
 * changed set, the text `null` for nothing to redo, a null pointer for a refusal.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_redo(struct CadaclysmBlacksmithDocument *doc);

/**
 * The parameters as a JSON object, name to value. Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_params(const struct CadaclysmBlacksmithDocument *doc);

/**
 * Evaluates the nodes that are stale (only the cheap ones when `cheap_only`). The status of every
 * node as JSON, `[{"id", "state": "ok"|"error"|"blocked"|"pending", "key", "error"?, "by"?, "hash"?}]`.
 * Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_evaluate(struct CadaclysmBlacksmithDocument *doc,
                                             bool cheap_only);

/**
 * What node `id` evaluated to: `"solid"`, `"sheet"`, `"profile"`, `"profiles"` (a profile list,
 * or a sketch's outlines), `"nurbs"`, `"subd"`, `"curve"`, `"list"` (a list holding geometry, as a
 * laced node gives: its items are `id#0`, `id#1`, ..., read by every result call, and
 * [`cadaclysm_blacksmith_document_value`] counts them), `"value"` (a number, text, point, record
 * and the like: read it with [`cadaclysm_blacksmith_document_value`]), or `"none"` (no such node,
 * or not evaluated yet or failed). Owned.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_result_kind(const struct CadaclysmBlacksmithDocument *doc,
                                                const char *id);

/**
 * Node `id`'s solid or sheet as a new handle: free it with [`cadaclysm_blacksmith_solid_free`].
 * Null and `last_error` when `id` is not an evaluated solid or sheet.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_document_result_solid(const struct CadaclysmBlacksmithDocument *doc,
                                                                            const char *id);

/**
 * Node `id`'s profile as a new handle: free it with [`cadaclysm_blacksmith_profile_free`].
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile(const struct CadaclysmBlacksmithDocument *doc,
                                                                                const char *id);

/**
 * How many profiles node `id` holds, when it is a profile list (or a sketch). `UINT32_MAX` and
 * `last_error` otherwise.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
uint32_t cadaclysm_blacksmith_document_result_profile_count(const struct CadaclysmBlacksmithDocument *doc,
                                                            const char *id);

/**
 * Profile `i` of node `id`'s list, as a new handle: free it with
 * [`cadaclysm_blacksmith_profile_free`]. Null and `last_error` past the end.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile_at(const struct CadaclysmBlacksmithDocument *doc,
                                                                                   const char *id,
                                                                                   uint32_t i);

/**
 * Node `id`'s NURBS curve as a new handle: free it with [`cadaclysm_blacksmith_nurbs_curve_free`].
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_document_result_nurbs_curve(const struct CadaclysmBlacksmithDocument *doc,
                                                                                       const char *id);

/**
 * Node `id`'s subdivision cage as a new handle: free it with [`cadaclysm_blacksmith_subd_free`].
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_document_result_subd(const struct CadaclysmBlacksmithDocument *doc,
                                                                          const char *id);

/**
 * Node `id`'s value as JSON (a number, record, list, text, ...). Owned. Null and `last_error`
 * (the node's error, or that it has not been evaluated) when it has none.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_value(const struct CadaclysmBlacksmithDocument *doc,
                                          const char *id);

/**
 * The nodes the last evaluate left in error or blocked, `[{"id", "state", "message"}]`. Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_errors(const struct CadaclysmBlacksmithDocument *doc);

/**
 * Every node kind the library knows, as a JSON array of rows (name, inputs, output, cost, help).
 * Needs no document. Owned.
 */
char *cadaclysm_blacksmith_document_kinds(void);

/**
 * `solid` as the `body` field of a `solid.body` (or `sheet.body`) node holds it: the kernel's
 * own B-rep as JSON, every table and number as they are, and its colours (the solid's, each
 * face's, every edge's and each edge's), so the node gives back exactly this body as it is
 * drawn. How a solid the caller already has goes into a document. Needs no document. Owned.
 * Null and `last_error` where the solid holds a curve the kernel could not read.
 *
 * # Safety
 * `solid` a live solid.
 */
char *cadaclysm_blacksmith_document_solid_body(const struct CadaclysmBlacksmithSolid *solid);

/**
 * `profile` as the `path` field of a `profile.path` node holds it: its exact segments (lines,
 * arcs, Beziers, conics, NURBS), holes and colour as JSON, `{"start", "segments", "holes",
 * "colour"}`. How a profile the caller already has goes into a document, drawn as it was. Needs no document. Owned.
 *
 * # Safety
 * `profile` a live profile.
 */
char *cadaclysm_blacksmith_document_profile_path(const struct CadaclysmBlacksmithProfile *profile);

/**
 * A new branch `name` at commit `at` (null or empty: the head, and the document switches onto
 * it). The changed set, owned. Null and `last_error` when refused.
 *
 * # Safety
 * `doc` a live document; `name` a NUL-terminated UTF-8 string; `at` null or the same.
 */
char *cadaclysm_blacksmith_document_branch_new(struct CadaclysmBlacksmithDocument *doc,
                                               const char *name,
                                               const char *at);

/**
 * Moves the head to the branch `name_or_commit_id` (a branch name first, else a commit id, which
 * detaches the head). The changed set, owned. Null and `last_error` when refused.
 *
 * # Safety
 * `doc` a live document; `name_or_commit_id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_branch_switch(struct CadaclysmBlacksmithDocument *doc,
                                                  const char *name_or_commit_id);

/**
 * The tips of lines no branch names, each a whole commit as [`cadaclysm_blacksmith_document_log`]
 * writes it, `[{"id", "parents", "message"?, "author"?, "time"?, "ops"}]`. Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_tips(const struct CadaclysmBlacksmithDocument *doc);

/**
 * Renames branch `old` to `new`. False and `last_error` when refused.
 *
 * # Safety
 * `doc` a live document; `old`, `new` NUL-terminated UTF-8 strings.
 */
bool cadaclysm_blacksmith_document_branch_rename(struct CadaclysmBlacksmithDocument *doc,
                                                 const char *old,
                                                 const char *new_);

/**
 * Deletes branch `name`. False and `last_error` when refused.
 *
 * # Safety
 * `doc` a live document; `name` a NUL-terminated UTF-8 string.
 */
bool cadaclysm_blacksmith_document_branch_delete(struct CadaclysmBlacksmithDocument *doc,
                                                 const char *name);

/**
 * The branches as JSON, `{"branches": {name: commit}, "branch": name|null, "head": commit,
 * "unnamed": [commit]}`, plus `"can_undo"` and `"can_redo"`. Owned.
 *
 * # Safety
 * `doc` a live document.
 */
char *cadaclysm_blacksmith_document_branch_list(const struct CadaclysmBlacksmithDocument *doc);

/**
 * The commits of `branch`'s line (null or empty: the line from the head to the root), newest first,
 * `[{"id", "parents", "message"?, "author"?, "time"?, "ops"}]`. Owned. Null and `last_error`
 * for a branch that does not exist.
 *
 * # Safety
 * `doc` a live document; `branch` null or a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_log(const struct CadaclysmBlacksmithDocument *doc,
                                        const char *branch);

/**
 * Release a document. Null is a no-op.
 *
 * # Safety
 * `doc` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_document_free(struct CadaclysmBlacksmithDocument *doc);

/**
 * A new building document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`; null or
 * empty is `mm`): the blacksmith kinds and the `bim.*` ones, holding one hidden `bim.project`
 * node with a random guid, the seed of every IFC GlobalId it exports (added as one commit).
 * Free it with [`cadaclysm_blacksmith_document_free`]. Null and `last_error` for unknown units.
 *
 * # Safety
 * `units` null or a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithDocument *cadaclysm_bim_document_new(const char *units);

/**
 * A building document read from `text`, as [`cadaclysm_blacksmith_document_save`] writes it,
 * opened with the `bim.*` kinds. Free it with [`cadaclysm_blacksmith_document_free`]. Null and
 * `last_error` for text that is not a document.
 *
 * # Safety
 * `text` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithDocument *cadaclysm_bim_document_load(const char *text);

/**
 * Every node kind a building document knows, the blacksmith's and the `bim.*` ones, as
 * [`cadaclysm_blacksmith_document_kinds`] lists them. Owned: release it with
 * [`cadaclysm_blacksmith_string_free`].
 */
char *cadaclysm_bim_kinds(void);

/**
 * The building as IFC text. `options_json` (null or empty: every default) is
 * `{"schema": "IFC4" | "IFC2X3", "geometry": "parametric" | "exact", "timestamp": <Unix
 * seconds>, "name": <IfcProject name>}`, every key optional (IFC4, parametric, the current
 * time, no name; an explicit `"timestamp": 0` is the epoch, for byte-stable files).
 * The document is evaluated first if it is not. Owned: release it with
 * [`cadaclysm_blacksmith_string_free`].
 *
 * Null and `last_error` for a document not opened as a building document, for bad options,
 * and for a refused export, whose reason is every refusal at once as JSON,
 * `bim_document_export_ifc: {"refusals": [{"node": <id> | null, "reason": <text>}]}`: nothing
 * is written then.
 *
 * # Safety
 * `doc` a live document; `options_json` null or a NUL-terminated UTF-8 string.
 */
char *cadaclysm_bim_document_export_ifc(struct CadaclysmBlacksmithDocument *doc,
                                        const char *options_json);

/**
 * Replaces the catalogue `parts.catalog` builds from with the one in directory `dir`: its
 * `index.json` and every family file it lists (the robot bench's `catalog/`). False and
 * `last_error` for a directory that is not a catalogue.
 *
 * # Safety
 * `dir` a NUL-terminated UTF-8 string.
 */
bool cadaclysm_parts_catalog_load(const char *dir);

/**
 * A new, empty bench document, in mm: the blacksmith kinds (`assembly.*` among them) and
 * `parts.*`. Free it with [`cadaclysm_blacksmith_document_free`].
 */
struct CadaclysmBlacksmithDocument *cadaclysm_parts_document_new(void);

/**
 * A bench document read from `text`, as [`cadaclysm_blacksmith_document_save`] writes it, opened
 * with the `parts.*` kinds. Free it with [`cadaclysm_blacksmith_document_free`]. Null and
 * `last_error` for text that is not a document ("This is not a cadaclysm-blacksmith document",
 * naming an old robot bench project when it is one).
 *
 * # Safety
 * `text` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithDocument *cadaclysm_parts_document_load(const char *text);

/**
 * Every node kind a bench document knows, the blacksmith's and the `parts.*` ones, as
 * [`cadaclysm_blacksmith_document_kinds`] lists them. Owned: release it with
 * [`cadaclysm_blacksmith_string_free`].
 */
char *cadaclysm_parts_kinds(void);

/**
 * Fill `options` with `size` set and every default in place: a chordal tolerance and no size
 * ceiling, exactly as `FemOptions::default()` states them -- the numbers are not restated
 * here, so the two cannot drift.
 *
 * **This is the one call the size rule does not protect.** [`cadaclysm_blacksmith_fem_mesh`]
 * reads only the fields `size` says are there, so a caller built against an older header is
 * safe against a newer library. This function has no such input to read: it writes
 * `sizeof(CadaclysmBlacksmithFemOptions)` bytes as **this library** knows that type, and a
 * caller compiled against an older, shorter header has only that many bytes of stack local to
 * receive them into. Its header must be at least as new as the library it links.
 *
 * # Safety
 * `options` must be null, or point at writable storage of at least
 * `sizeof(CadaclysmBlacksmithFemOptions)` bytes, `sizeof` taken from a header at least as new
 * as this library -- see above.
 */
void cadaclysm_blacksmith_fem_options_init(struct CadaclysmBlacksmithFemOptions *options);

/**
 * One solid's mesh for a solver: nodes welded by bits, triangles wound outward, each node
 * tagged with the lowest-dimension B-rep entity it lies on, and every crack reported rather
 * than closed.
 *
 * `placement` is null (the identity) or **twelve doubles -- origin, x, y, z, as every frame
 * argument in this library; right-handed and orthonormal** -- and is applied in `f64`
 * throughout. It is the one frame argument here that may be null, because a body meshed in its
 * own coordinates is the common case where a sweep without a frame is nothing at all. The
 * reader library's `cadaclysm_node_fem_mesh` takes **sixteen**, column-major, as everything on
 * that side does; a caller moving between the two reformats the placement.
 *
 * `options` is null (every default) or a struct filled by
 * [`cadaclysm_blacksmith_fem_options_init`] -- whose **`max_size` bounds the boundary segments and
 * merely targets the interior**, and one small enough beside the body to reach the mesher's own
 * piece and station ceilings is not honoured at all: `CadaclysmBlacksmithFemMeshView::longest_edge`
 * is what the mesh actually came to, and the figure a caller that asked for an element size checks
 * to find out whether it got one. `tolerance` alone decides how closely the boundary follows the
 * geometry. (Also on `CadaclysmBlacksmithFemOptions::max_size` and
 * `CadaclysmBlacksmithFemMeshView::longest_edge`, and stated here because a C reader meets a
 * struct member's own comment nowhere but the header itself -- the docs pages carry a struct as
 * its declaration alone.)
 *
 * `progress` is null (silent) or a callback that receives the two phases **`meshing`** and
 * **`welding`**, `done` of `total` within each, as the booleans report theirs; `user` comes
 * back untouched. **Its obligations are
 * [`CadaclysmBlacksmithProgress`](crate::CadaclysmBlacksmithProgress)'s**, in full and
 * unchanged: it is called on *this* thread, often, so a sink that forwards elsewhere throttles
 * itself, and it must not call back into this library.
 *
 * **An opened phase is not a promise of a closed one.** Nothing is reported at all when the
 * call is refused for its inputs -- a bad `size`, tolerance, `max_size` or placement comes back
 * null with no phase ever opened -- and a body that meshes to no triangles reports `meshing`
 * through to `1 of 1` and then fails with **no `welding`**, because that close says the mesher
 * finished, not that it produced something. A watcher that draws a bar on the first report, or
 * that waits for `welding` before believing the call ended, needs both of those.
 *
 * **A cracked body is not a failure.** It comes back with `watertight` false and its cracks in
 * the two censuses; nothing is welded shut to make it look sound. Null, with
 * [`cadaclysm_blacksmith_last_error`](crate::cadaclysm_blacksmith_last_error) saying why, for
 * `fem_mesh: null solid`, a bad `size`, a tolerance or `max_size` the mesher refuses, a
 * placement not finite or not invertible, and a body that meshes to no triangles at all.
 *
 * Free it with [`cadaclysm_blacksmith_fem_mesh_free`].
 *
 * # Safety
 * `solid` must be a live solid; `placement` null or twelve readable doubles; `options` null or
 * a struct whose `size` bytes are readable; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithFemMesh *cadaclysm_blacksmith_fem_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                                 const double *placement,
                                                                 const struct CadaclysmBlacksmithFemOptions *options,
                                                                 CadaclysmBlacksmithProgress progress,
                                                                 void *user);

/**
 * Release a FEM mesh, and with it every pointer any accessor handed out. Null is a no-op. The
 * `.msh` texts are **not** freed with it: each is the caller's, and each outlives this.
 *
 * # Safety
 * `m` must have come from [`cadaclysm_blacksmith_fem_mesh`] and not have been freed already.
 */
void cadaclysm_blacksmith_fem_mesh_free(struct CadaclysmBlacksmithFemMesh *m);

/**
 * The flat arrays and the summary of one FEM mesh, into `out`.
 *
 * `false` (and `last_error`) for a null handle or a null `out`; nothing is written then.
 *
 * # Safety
 * `m` must be null or a handle from [`cadaclysm_blacksmith_fem_mesh`] that has not been freed;
 * `out` must be null or point at writable storage for one `CadaclysmBlacksmithFemMeshView`.
 */
bool cadaclysm_blacksmith_fem_mesh_view(const struct CadaclysmBlacksmithFemMesh *m,
                                        struct CadaclysmBlacksmithFemMeshView *out);

/**
 * B-rep edge `i` of a FEM mesh, into `out`.
 *
 * `false` (and `last_error`) for a null handle, a null `out`, or an `i` at or past
 * `CadaclysmBlacksmithFemMeshView::edge_count`; nothing is written then.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_fem_mesh_view`], with `out` a `CadaclysmBlacksmithFemEdge`.
 */
bool cadaclysm_blacksmith_fem_mesh_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                        uint32_t i,
                                        struct CadaclysmBlacksmithFemEdge *out);

/**
 * B-rep vertex `i` of a FEM mesh, into `out`.
 *
 * `false` (and `last_error`) for a null handle, a null `out`, or an `i` at or past
 * `CadaclysmBlacksmithFemMeshView::vertex_count`; nothing is written then. A vertex with no
 * node and no position is **not** a failure: it comes back `true` with
 * `node == CADACLYSM_BLACKSMITH_NONE` and `has_position == false`.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_fem_mesh_view`], with `out` a `CadaclysmBlacksmithFemVertex`.
 */
bool cadaclysm_blacksmith_fem_mesh_vertex(const struct CadaclysmBlacksmithFemMesh *m,
                                          uint32_t i,
                                          struct CadaclysmBlacksmithFemVertex *out);

/**
 * Crack `i`: a directed mesh edge `(a, b)` with no `(b, a)`, and the B-rep edge both nodes lie
 * on or [`CADACLYSM_BLACKSMITH_NONE`] where they share none.
 *
 * `false` (and `last_error`) for a null handle, a null out-pointer, or an `i` at or past
 * `CadaclysmBlacksmithFemMeshView::open_edge_count`.
 *
 * **Empty unless the solid's topology is closed** -- see
 * `CadaclysmBlacksmithFemMeshView::watertight`, which explains what an empty census does and
 * does not mean.
 *
 * # Safety
 * `m` as [`cadaclysm_blacksmith_fem_mesh_view`]; `a`, `b` and `brep_edge` each null or a
 * writable `uint32_t`.
 */
bool cadaclysm_blacksmith_fem_mesh_open_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                             uint32_t i,
                                             uint32_t *a,
                                             uint32_t *b,
                                             uint32_t *brep_edge);

/**
 * Fold `i`: a directed mesh edge used by more than one triangle, with its B-rep edge as
 * [`cadaclysm_blacksmith_fem_mesh_open_edge`] reports one.
 *
 * **A body can be folded without being open**, and the closure census's own pinned rows are
 * folds: a caller that checks only `open_edge_count` calls such a body sound. `false` (and
 * `last_error`) for a null handle, a null out-pointer, or an `i` at or past
 * `CadaclysmBlacksmithFemMeshView::folded_edge_count`.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_fem_mesh_open_edge`].
 */
bool cadaclysm_blacksmith_fem_mesh_folded_edge(const struct CadaclysmBlacksmithFemMesh *m,
                                               uint32_t i,
                                               uint32_t *a,
                                               uint32_t *b,
                                               uint32_t *brep_edge);

/**
 * How many pairs of this mesh's triangles pass through each other: the rows
 * [`cadaclysm_blacksmith_fem_mesh_crossing`] reads. 0 (and `last_error`) for a null handle.
 *
 * **In its own function because `CadaclysmBlacksmithFemMeshView` cannot grow**: callers
 * allocate the view. A mesh is ready for a volume mesher when `watertight` is true **and**
 * this is 0.
 *
 * # Safety
 * `m` as [`cadaclysm_blacksmith_fem_mesh_view`].
 */
uint32_t cadaclysm_blacksmith_fem_mesh_crossing_count(const struct CadaclysmBlacksmithFemMesh *m);

/**
 * Crossing `i`: the triangles `a < b` that pass through each other. `false` (and `last_error`)
 * for a null handle, a null out-pointer, or an `i` at or past
 * [`cadaclysm_blacksmith_fem_mesh_crossing_count`]; nothing written then.
 *
 * # Safety
 * `m` as [`cadaclysm_blacksmith_fem_mesh_view`]; `a` and `b` each null or a writable `uint32_t`.
 */
bool cadaclysm_blacksmith_fem_mesh_crossing(const struct CadaclysmBlacksmithFemMesh *m,
                                            uint32_t i,
                                            uint32_t *a,
                                            uint32_t *b);

/**
 * The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a volume
 * where the body closes, and a physical group naming each.
 *
 * **The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`](crate::cadaclysm_blacksmith_string_free)**, as every
 * other text this library hands over. Two asks give two texts, each independent of the other
 * and of the handle: a text stays good after
 * [`cadaclysm_blacksmith_fem_mesh_free`]. (The reader library's `cadaclysm_fem_mesh_msh_text`
 * borrows from a slot on its own handle instead and must **not** be freed -- see this module's
 * own documentation.)
 *
 * Null (and `last_error`) for a null handle or a mesh the writer refuses -- the writer states
 * a field it cannot honour, and that refusal arrives here as a message, not as a crash.
 *
 * # Safety
 * `m` must be null or a handle from [`cadaclysm_blacksmith_fem_mesh`] that has not been freed.
 */
char *cadaclysm_blacksmith_fem_mesh_msh_text(const struct CadaclysmBlacksmithFemMesh *m);

/**
 * [`cadaclysm_blacksmith_fem_mesh_msh_text`] written to `path`, replacing any file there: the
 * same bytes, from the same writer, straight to the file rather than through a string.
 *
 * `false` (and `last_error`) for a null handle, no path, a mesh the writer refuses, or a file
 * it cannot write.
 *
 * # Safety
 * `m` as [`cadaclysm_blacksmith_fem_mesh_view`]; `path` must be null or a valid C string.
 */
bool cadaclysm_blacksmith_fem_mesh_save_msh(const struct CadaclysmBlacksmithFemMesh *m,
                                            const char *path);

/**
 * Remove the features smaller than `tolerance` that
 * [`cadaclysm_blacksmith_health`](crate::cadaclysm_blacksmith_health) lists as small: short and
 * collapsed edges, sliver and tiny faces, small holes. Every fix is a vertex merge; each edge
 * moved records how far as its tolerance ([`cadaclysm_blacksmith_edge_tolerance`]). A guard
 * compares the result's health with the input's and refuses fixes that made it worse (the
 * summary's `guarded`). `solid` is left as it was; the healed solid keeps its name and colours.
 * `NaN` or `tolerance <= 0` takes the default, `1e-4` times the diagonal of the body's edge
 * points -- or, where the solid declares an absolute tolerance, the larger of that declaration
 * and `tolerance.relative` times the same diagonal (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance));
 * the summary's `sizes[0]` says what was used. `flags` picks what is fixed: 1 edges,
 * 2 faces, 4 holes, 7 all; a kind switched off is refused as toggled.
 *
 * A report handle, read with the `cadaclysm_blacksmith_heal_*` accessors and freed with
 * [`cadaclysm_blacksmith_heal_free`]; null (and `last_error`) on a null `solid` or a flag bit
 * other than those three.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithHeal *cadaclysm_blacksmith_healed(const struct CadaclysmBlacksmithSolid *solid,
                                                            double tolerance,
                                                            uint32_t flags);

/**
 * The healed solid: a new solid the caller frees with
 * [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free), each call a
 * solid of its own (sharing the body, not copying it). It outlives the report. Null (and
 * `last_error`) on a null `h`.
 *
 * # Safety
 * `h` null or live from [`cadaclysm_blacksmith_healed`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_heal_body(const struct CadaclysmBlacksmithHeal *h);

/**
 * Free a report. Null is a no-op. A solid taken with [`cadaclysm_blacksmith_heal_body`] stays
 * good.
 *
 * # Safety
 * `h` null or from [`cadaclysm_blacksmith_healed`], and freed once.
 */
void cadaclysm_blacksmith_heal_free(struct CadaclysmBlacksmithHeal *h);

/**
 * The report's figures. `counts`, eleven `uint32_t`, in order: fixes, refused, guarded, small
 * before, small after, free edges before, free edges after, closed before, closed after,
 * non-manifold edges before, non-manifold edges after (before and after are the input's and the
 * result's health at the tolerance used). `sizes`, two `double`: the tolerance used, the
 * furthest any trim moved. Either output may be null; not both. `false` (and `last_error`) on a
 * null `h` or both outputs null.
 *
 * # Safety
 * `h` null or live from [`cadaclysm_blacksmith_healed`]; `counts` null or eleven `uint32_t`;
 * `sizes` null or two `double`.
 */
bool cadaclysm_blacksmith_heal_summary(const struct CadaclysmBlacksmithHeal *h,
                                       uint32_t *counts,
                                       double *sizes);

/**
 * The features removed, in the order they were, one row each: `items`, two `uint32_t` -- kind
 * (0 short edge, 1 collapsed edge, 2 sliver face, 3 tiny face, 4 tiny body, 5 small hole), index
 * (as in [`cadaclysm_blacksmith_health_small`](crate::cadaclysm_blacksmith_health_small), of the
 * input); `sizes`, two `double` -- its size, the furthest a vertex it merged moved. Returns the
 * count; with both buffers null it writes nothing, so call it twice: once to size the buffers,
 * once to fill them. A non-null buffer must hold the whole count. Zero (and `last_error`) on a
 * null `h`.
 *
 * # Safety
 * `h` null or live from [`cadaclysm_blacksmith_healed`]; `items` null or `2 n` `uint32_t`,
 * `sizes` null or `2 n` `double`, for `n` the count.
 */
uint32_t cadaclysm_blacksmith_heal_fixes(const struct CadaclysmBlacksmithHeal *h,
                                         uint32_t *items,
                                         double *sizes);

/**
 * The small features left, one row each: `items`, three `uint32_t` -- kind (as in
 * [`cadaclysm_blacksmith_heal_fixes`]), index, why (0 would empty its loop, 1 closed, 2 seam,
 * 3 chain wider than the tolerance, 4 a sliver's neighbours part, 5 uneven sliver sides, 6
 * non-manifold, 7 has holes, 8 the body guard, 9 toggled off by `flags`, 10 unsupported);
 * `sizes`, one `double` -- the why's figure (a chain's width, the neighbours' gap, else 0).
 * Returns the count, with the two-call convention of [`cadaclysm_blacksmith_heal_fixes`].
 *
 * # Safety
 * `h` null or live; `items` null or `3 n` `uint32_t`, `sizes` null or `n` `double`.
 */
uint32_t cadaclysm_blacksmith_heal_refused(const struct CadaclysmBlacksmithHeal *h,
                                           uint32_t *items,
                                           double *sizes);

/**
 * How far edge `edge` (a brep edge id, as a fix's index names one) may lie off its curve: 0 for
 * an exact edge, the distance healing (or sewing) moved it where that is recorded, `NaN` when no
 * trim of a face's loop names the id (an edge healing removed) or (with `last_error`) `solid` is
 * null.
 *
 * # Safety
 * `solid` null or live.
 */
double cadaclysm_blacksmith_edge_tolerance(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t edge);

/**
 * Diagnose a solid's body: its free edges and the wires they chain into, the features smaller
 * than `tolerance`, what a dry-run sew would do, and (with `mesh`) the cracks of its mesh.
 * `solid` is left as it was. `NaN` or `tolerance <= 0` takes the default, `1e-4` times the
 * diagonal of the body's edge points -- or, where the solid declares an absolute tolerance, the
 * larger of that declaration and `tolerance.relative` times the same diagonal, as
 * [`cadaclysm_blacksmith_healed`](crate::cadaclysm_blacksmith_healed) heals; the report's
 * `sizes[0]` says what was used. With `mesh` the body is also meshed at that tolerance, which
 * costs time on a large body.
 *
 * A report handle, read with the `cadaclysm_blacksmith_health_*` accessors and freed with
 * [`cadaclysm_blacksmith_health_free`]; null (and `last_error`) on a null `solid`.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithHealth *cadaclysm_blacksmith_health(const struct CadaclysmBlacksmithSolid *solid,
                                                              double tolerance,
                                                              bool mesh);

/**
 * Free a report. Null is a no-op.
 *
 * # Safety
 * `health` null or from [`cadaclysm_blacksmith_health`], and freed once.
 */
void cadaclysm_blacksmith_health_free(struct CadaclysmBlacksmithHealth *health);

/**
 * The report's figures. `counts`, eighteen `uint32_t`, in order: free edges, wires, closed
 * wires, small features, short edges, collapsed edges, sliver faces, tiny faces, tiny body,
 * loose edges, sew pairs, sew refused, meshed, watertight, open, folded, crossings, crack edges
 * (the last six are 0 unless the report was made with `mesh`, and `meshed` is 1 then). `sizes`,
 * eight `double`: tolerance used, rounding, extent, worst free-edge gap (largest finite, 0 if
 * none), worst loose edge, sew worst gap, shortest edge, narrowest face (0 if none). Either
 * output may be null; not both. `false` (and `last_error`) on a null `health` or both outputs
 * null.
 *
 * # Safety
 * `health` null or live from [`cadaclysm_blacksmith_health`]; `counts` null or eighteen
 * `uint32_t`; `sizes` null or eight `double`.
 */
bool cadaclysm_blacksmith_health_summary(const struct CadaclysmBlacksmithHealth *health,
                                         uint32_t *counts,
                                         double *sizes);

/**
 * The free edges (the sides one face bounds), one row each: `ids`, six `uint32_t` per edge --
 * trim, edge, face, wire, partner, shared ends (edge and partner are `UINT32_MAX` where there is
 * none); `sizes`, two `double` per edge -- length, gap to its partner (`+inf` with none).
 * Returns the count; with both buffers null it writes nothing, so call it twice: once to size
 * the buffers, once to fill them. A non-null buffer must hold the whole count. Zero (and
 * `last_error`) on a null `health`.
 *
 * # Safety
 * `health` null or live from [`cadaclysm_blacksmith_health`]; `ids` null or `6 n` `uint32_t`,
 * `sizes` null or `2 n` `double`, for `n` the count.
 */
uint32_t cadaclysm_blacksmith_health_free_edges(const struct CadaclysmBlacksmithHealth *health,
                                                uint32_t *ids,
                                                double *sizes);

/**
 * The free wires (the free edges chained end to end), one row each: `runs`, three `uint32_t` per
 * wire -- first, count, closed (the free-edge rows it covers); `sizes`, two `double` -- length,
 * widest gap. Returns the count, with the two-call convention of
 * [`cadaclysm_blacksmith_health_free_edges`].
 *
 * # Safety
 * `health` null or live; `runs` null or `3 n` `uint32_t`, `sizes` null or `2 n` `double`.
 */
uint32_t cadaclysm_blacksmith_health_wires(const struct CadaclysmBlacksmithHealth *health,
                                           uint32_t *runs,
                                           double *sizes);

/**
 * The features below the tolerance, one row each: `items`, two `uint32_t` -- kind (0 short edge,
 * 1 collapsed edge, 2 sliver face, 3 tiny face, 4 tiny body, 5 small hole), index (a hole's is
 * its loop); `sizes`, one `double` -- its size. Returns the count, with the two-call convention of
 * [`cadaclysm_blacksmith_health_free_edges`].
 *
 * # Safety
 * `health` null or live; `items` null or `2 n` `uint32_t`, `sizes` null or `n` `double`.
 */
uint32_t cadaclysm_blacksmith_health_small(const struct CadaclysmBlacksmithHealth *health,
                                           uint32_t *items,
                                           double *sizes);

/**
 * The edge ids the mesh cracks along (none unless the report was made with `mesh`). Returns the
 * count, with the two-call convention of [`cadaclysm_blacksmith_health_free_edges`].
 *
 * # Safety
 * `health` null or live; `ids` null or `n` `uint32_t`.
 */
uint32_t cadaclysm_blacksmith_health_crack_edges(const struct CadaclysmBlacksmithHealth *health,
                                                 uint32_t *ids);

/**
 * The tolerance a verb given none works at over `count` solids.
 *
 * # Tolerances
 *
 * A solid **declares** how precise it is: an absolute tolerance (a length, in the model's own
 * units) and an angular one (radians), each read from the file it came from (a 3dm's units and
 * tolerances, STEP's uncertainty, SAT's `resabs`, IGES's resolution), carried by every verb's
 * result as the loosest of its inputs', scaled with the solid by a transform, and set by
 * [`cadaclysm_blacksmith_solid_with_tolerances`]. [`cadaclysm_blacksmith_solid_tolerances`]
 * reads it back, NaN where the source said nothing.
 *
 * **0 or NaN is unset, in every verb that takes a distance tolerance** (booleans, fillets,
 * shells, splits, sections, hits, closest, classifiers, colliders, clash, meshes, curve fits
 * and projections, profile verbs): the verb works at the inputs' **effective** tolerance,
 * this call's answer -- the larger of the loosest absolute tolerance they declare and the
 * option `tolerance.relative` (default `1e-4`) times their size, never finer than their
 * coordinates can represent. A named tolerance is used exactly as given; a negative or
 * infinite one is still the verb's refusal. `healed`/`health` take any value `<= 0` as
 * unset, and `join_sheets` 0 as its own rounding gap, each made at least the declaration.
 * **0 is exact, not unset**, in three calls: `nurbs_curve_joined` (0 joins only ends that meet
 * exactly; it takes no NaN), and `solid_value_contains` and `rectangle_contains`, whose 0
 * counts only a point exactly on the boundary as on it and whose NaN is unset, the value's own
 * effective tolerance (`tolerance.relative` times its diagonal, never finer than its
 * coordinates' rounding).
 * The option `tolerance.angular` (default 1 degree) applies where nothing declares an angle.
 * Accuracies that are shares, not lengths (mass properties, `oriented_box`), are unchanged.
 *
 * 0 for `count` 0 (`solids` may then be null) or solids with nothing to size by -- which a
 * verb refuses. NaN, with [`cadaclysm_blacksmith_last_error`](crate::cadaclysm_blacksmith_last_error),
 * for a null array or a null solid in it.
 *
 * # Safety
 * `solids` null with `count` 0, or `count` pointers, each null or a live solid.
 */
double cadaclysm_blacksmith_effective_tolerance(const struct CadaclysmBlacksmithSolid *const *solids,
                                                size_t count);

/**
 * What `solid` declares about its own precision (see the tolerances section at
 * [`cadaclysm_blacksmith_effective_tolerance`]): its absolute tolerance into `*absolute` and its
 * angular one (radians) into `*angular`, NaN for one it does not declare. Either pointer may be
 * null. False, with `last_error`, for a null solid.
 *
 * # Safety
 * `solid` null or live; `absolute` and `angular` each null or room for one double.
 */
bool cadaclysm_blacksmith_solid_tolerances(const struct CadaclysmBlacksmithSolid *solid,
                                           double *absolute,
                                           double *angular);

/**
 * A new solid: `solid` declaring `absolute` (a length) and `angular` (radians) instead of what
 * it declared, its name, paint and marks kept. NaN or 0 declares nothing for that field. The
 * caller frees it with [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free).
 * Null, with `last_error`, for a null solid or a negative or infinite value.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_with_tolerances(const struct CadaclysmBlacksmithSolid *solid,
                                                                            double absolute,
                                                                            double angular);

/**
 * How loose the vertex of `solid` at (`x`, `y`, `z`) is, where its producer said (an OCCT
 * `.brep` records one per vertex): the tolerance of the nearest recorded vertex within its own
 * tolerance of the point. NaN where none is recorded there or the point is not finite, and
 * (with `last_error`) for a null solid.
 *
 * # Safety
 * `solid` null or live.
 */
double cadaclysm_blacksmith_vertex_tolerance(const struct CadaclysmBlacksmithSolid *solid,
                                             double x,
                                             double y,
                                             double z);

/**
 * Where `a`'s curves cross, touch or run along `b`'s, both read in one plane:
 * runs where two sides (lines, arcs or splines) stay within `tolerance` of
 * each other for longer than it, parting only where one of them ends or the
 * stretch is flat -- one curve following the other, offset within
 * `tolerance` or tilted by under about half of it, even where it leaves
 * mid-both -- and points, merged within `tolerance`, ordered along `a`. An
 * end within `tolerance` of the other curve meets it. A loop is its segments
 * alone -- one that stops short of its start is an open chain. Null (and
 * `last_error`) for a null profile, a `tolerance` negative or infinite, or
 * a spline segment that does not evaluate. No hits at all is a handle with a
 * count of 0.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * Where `profile`, placed on `frame` (twelve doubles), pierces `solid`'s
 * faces, and the pieces its loops cut into: points where a segment crosses a
 * face's exact surface, within `tolerance` and inside its trim, `touch` at a
 * graze; runs where a segment lies on a face, from where it enters to where
 * it leaves; merged within `tolerance` of each other (a hit at a segment
 * join reported once). `inside` for a piece is by its midpoint's winding
 * number over `solid`'s own mesh -- only reported for a closed body (its own
 * manifold/closed report): an open sheet's `pieces` is always empty, read
 * with [`cadaclysm_blacksmith_hits_piece_count`] alone. A loop no hit cuts is
 * one closed piece, all `inside` or all outside as the winding number says.
 * No hits at all is still such a handle, never null.
 *
 * Reports its phases -- "mesh", "cull", "hits", "pieces" -- to `progress` if
 * not null, as the booleans do.
 *
 * Null (and `last_error`) for a null `solid` (`"solid_profile_hits: null
 * solid"`), a null `profile` (`"... null profile"`), a null `frame` (`"...
 * null frame"`), a `tolerance` negative or infinite, a solid with no
 * faces or that meshes to nothing, a profile with no segments, or a
 * free-form segment that does not evaluate to a NURBS curve.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` and `profile` live handles; `frame` twelve doubles; `progress`
 * null or a valid callback.
 */
struct CadaclysmBlacksmithHits *cadaclysm_blacksmith_solid_profile_hits(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const struct CadaclysmBlacksmithProfile *profile,
                                                                        const double *frame,
                                                                        double tolerance,
                                                                        CadaclysmBlacksmithProgress progress,
                                                                        void *user);

/**
 * How many pieces `hits` (from [`cadaclysm_blacksmith_solid_profile_hits`])
 * cut the profile's loops into. 0 for a `hits` read from
 * [`cadaclysm_blacksmith_profile_hits`] instead (profile x profile has no
 * solid to be inside of), for an open sheet, and (and `last_error`) for
 * null.
 *
 * # Safety
 * `hits` live.
 */
uint32_t cadaclysm_blacksmith_hits_piece_count(const struct CadaclysmBlacksmithHits *hits);

/**
 * Piece `i` (below [`cadaclysm_blacksmith_hits_piece_count`]): `*inside`
 * true where the piece's midpoint winds inside `solid`, false outside (true
 * too where the piece lies flat on the solid's surface); `*start` and `*end`
 * the profile spots it runs between, in loop order, covering every loop
 * exactly -- a loop no hit cuts is one whole piece round the loop whose
 * `start` and `end` are both `(0, t=0)`; an open chain's own first and last
 * pieces run from its own start and to its own end. `false` (and `last_error`) for null `hits`, a
 * null `inside`, `start` or `end`, or `i` out of range.
 *
 * # Safety
 * `hits` live; `inside`, `start` and `end` valid, writable.
 */
bool cadaclysm_blacksmith_hits_piece(const struct CadaclysmBlacksmithHits *hits,
                                     uint32_t i,
                                     bool *inside,
                                     struct CadaclysmBlacksmithSpot *start,
                                     struct CadaclysmBlacksmithSpot *end);

/**
 * Piece `i`'s own profile, as a handle of its own: the loop cut down to that
 * piece alone, running along its segments with no holes -- what
 * `cadaclysm_blacksmith_sweep_path_along(.., open: true)` sweeps. Free it
 * with [`cadaclysm_blacksmith_profile_free`]. Null (and `last_error`) for
 * null `hits` or `i` out of range.
 *
 * # Safety
 * `hits` live.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_hits_piece_profile(const struct CadaclysmBlacksmithHits *hits,
                                                                           uint32_t i);

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
 * An interpolator over `count` samples of `dimension` doubles each (`samples` holds
 * `count · dimension` doubles, sample `k` at `k · dimension`); `cyclic` wraps `t` round the list,
 * otherwise it is clamped to the first and last samples.
 *
 * Null and `last_error` for no samples (`count` 0), a `dimension` of 0, a null `samples` with
 * `count` above 0, and a sample with a NaN or infinite number, by its index.
 *
 * # Safety
 * `samples` readable for `count · dimension` doubles, or null with `count` 0.
 */
struct CadaclysmBlacksmithInterpolator *cadaclysm_blacksmith_interpolator_new(const double *samples,
                                                                              uint32_t count,
                                                                              uint32_t dimension,
                                                                              bool cyclic);

/**
 * How many samples. 0 (and `last_error`) for null.
 *
 * # Safety
 * `interpolator` live.
 */
uint32_t cadaclysm_blacksmith_interpolator_count(const struct CadaclysmBlacksmithInterpolator *interpolator);

/**
 * How many doubles per sample. 0 (and `last_error`) for null.
 *
 * # Safety
 * `interpolator` live.
 */
uint32_t cadaclysm_blacksmith_interpolator_dimension(const struct CadaclysmBlacksmithInterpolator *interpolator);

/**
 * Whether `t` wraps round the list. `false` (and `last_error`) for null.
 *
 * # Safety
 * `interpolator` live.
 */
bool cadaclysm_blacksmith_interpolator_cyclic(const struct CadaclysmBlacksmithInterpolator *interpolator);

/**
 * The value at the fractional index `t` by `mode` into `out`, `dimension` doubles.
 *
 * `false` and `last_error`, with `out` untouched, for a null interpolator or `out`, an `out_len`
 * under the dimension, a `t` that is NaN or infinite, and a mode that is not one of the five.
 *
 * # Safety
 * `interpolator` live; `out` writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_interpolator_at(const struct CadaclysmBlacksmithInterpolator *interpolator,
                                          double t,
                                          uint32_t mode,
                                          double *out,
                                          uint32_t out_len);

/**
 * The values at the `n` fractional indices `ts` by `mode` into `out`, flat: value `k` at
 * `k · dimension`, `n · dimension` doubles. `n = 0` writes nothing (`ts` and `out` may then be
 * null).
 *
 * `false` and `last_error`, with `out` untouched, for a null interpolator, `ts` or `out`, an
 * `out_len` under `n · dimension`, a value of `t` that is NaN or infinite (by its index), a mode
 * that is not one of the five, and `n` above 1 000 000.
 *
 * # Safety
 * `interpolator` live; `ts` readable for `n` doubles; `out` writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_interpolator_sample(const struct CadaclysmBlacksmithInterpolator *interpolator,
                                              const double *ts,
                                              uint32_t n,
                                              uint32_t mode,
                                              double *out,
                                              uint32_t out_len);

/**
 * Release an interpolator. Null is a no-op.
 *
 * # Safety
 * `interpolator` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_interpolator_free(struct CadaclysmBlacksmithInterpolator *interpolator);

/**
 * Where the faces of `a` and `b` cross or coincide, at `tolerance`: chains
 * along the curves the faces meet on ([`cadaclysm_blacksmith_intersection_chain`],
 * [`cadaclysm_blacksmith_intersection_curve`]) and, where a face pair
 * coincides, the shared region's outline ([`cadaclysm_blacksmith_intersection_overlap`]).
 * No crossing is a handle with zero of each, never null.
 *
 * Each chain's points are within `tolerance` of both faces' exact surfaces;
 * one chain per face pair per branch -- chains are not joined across a face
 * boundary or a closed curve's seam, so a caller joins them by matching ends;
 * `tangent` is set where the surfaces are near-tangent along the chain or the
 * snap did not settle within `tolerance` (the points are then the best
 * estimate); a closed chain that does not go once round its own curve --
 * a sliver of mesh noise where two surfaces barely cross -- is reported
 * with no curve at all (`cadaclysm_blacksmith_intersection_curve` then
 * says so by name), `tangent` still true. An overlap's rings are the
 * shared region's outline, outer first then holes, and may be empty for a
 * partial overlap of curved faces whose outlines cross.
 * Known limit: a crossing narrower than the mesh tolerance -- two surfaces
 * passing within `tolerance` without their meshes crossing -- can be missed;
 * near-tangent contact is where this bites.
 *
 * `tolerance` is expected well below the solids' extent (the kernel's own
 * suites use a few ten-thousandths of it): it is the mesh tolerance, and at a
 * tolerance comparable to the extent the meshes are a few facets, the chains
 * a few points, and a curve may be attached whose points, all within that
 * tolerance of it, do not run with its parameter.
 *
 * Reports its phases to `progress` if not null, as the booleans do: "meet" on
 * the exact route; "mesh", "cull", "cross", "snap", "curve" where it falls back
 * to the mesh route.
 *
 * Refuses `intersect: null solid`, `intersect: tolerance must be positive and
 * finite`, `intersect: solid a has no faces` (or `b has no faces`),
 * `intersect: a meshes to nothing` (or `b meshes to nothing`).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a`, `b` live solids; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_intersect(const struct CadaclysmBlacksmithSolid *a,
                                                                       const struct CadaclysmBlacksmithSolid *b,
                                                                       double tolerance,
                                                                       CadaclysmBlacksmithProgress progress,
                                                                       void *user);

/**
 * Release an intersection result. Null is a no-op.
 *
 * # Safety
 * `intersection` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_intersection_free(struct CadaclysmBlacksmithIntersection *intersection);

/**
 * How many chains. 0 (and `last_error`) for null.
 *
 * # Safety
 * `intersection` live.
 */
uint32_t cadaclysm_blacksmith_intersection_chain_count(const struct CadaclysmBlacksmithIntersection *intersection);

/**
 * Chain `i` into `out`. `false` (and `last_error`) for null `intersection`, a
 * null `out`, or `i` out of range.
 *
 * # Safety
 * `intersection` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_intersection_chain(const struct CadaclysmBlacksmithIntersection *intersection,
                                             uint32_t i,
                                             struct CadaclysmBlacksmithChain *out);

/**
 * Chain `i`'s exact curve into `out`, over the chain's own span on it -- see
 * [`cadaclysm_blacksmith_edge_curve`]'s doc for what each field means and the
 * range convention. The chain's points run WITH the curve's parameter: the
 * curve at `t0` is the chain's first point and at `t1` its last (to the
 * tolerance), and the parameter grows from each point to the next, round
 * the period of a closed curve; a closed chain has the curve's whole domain
 * and runs with it from its first point on. `false` (and `last_error`) for
 * null `intersection`, a null `out`, `i` out of range, or a chain with no
 * curve (`intersection_curve: chain {i} has no curve`).
 *
 * # Safety
 * `intersection` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_intersection_curve(const struct CadaclysmBlacksmithIntersection *intersection,
                                             uint32_t i,
                                             struct CadaclysmBlacksmithCurve *out);

/**
 * How many overlaps. 0 (and `last_error`) for null.
 *
 * # Safety
 * `intersection` live.
 */
uint32_t cadaclysm_blacksmith_intersection_overlap_count(const struct CadaclysmBlacksmithIntersection *intersection);

/**
 * Overlap `i` into `out`. `false` (and `last_error`) for null `intersection`,
 * a null `out`, or `i` out of range.
 *
 * # Safety
 * `intersection` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_intersection_overlap(const struct CadaclysmBlacksmithIntersection *intersection,
                                               uint32_t i,
                                               struct CadaclysmBlacksmithOverlap *out);

/**
 * `solid` tracked: its faces numbered 1..n in face order, its edges 1..m in the edge
 * table's order, each its own origin as operand 0. A tracked solid comes back as it is
 * (a new handle with the same ids). Null and `last_error` for a null solid.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_tracked(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Whether `solid` carries face and edge ids. `false` (and `last_error`) for null.
 *
 * # Safety
 * `solid` live.
 */
bool cadaclysm_blacksmith_solid_is_tracked(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Face `face`'s id. An id is unique within its solid and never 0; it stays with the
 * face through every verb that keeps the face (a move, a boolean, a fillet of another
 * edge), so it names "the same face, through my edits" within a session. A verb's
 * output face keeps the id of the input face it lies on; a piece split off, a face of a
 * later operand whose id an earlier one already has, and a face on no input get fresh
 * ids above every input's, in face order -- the same verbs on the same inputs number
 * the same, run after run. Ids are not written to files: to find a face on a model
 * rebuilt or read again, use [`cadaclysm_blacksmith_face_ref`].
 *
 * 0 where `solid` is untracked (no `last_error`); 0 and `last_error` for a face the
 * solid does not have or a null solid.
 *
 * # Safety
 * `solid` live.
 */
uint64_t cadaclysm_blacksmith_face_id(const struct CadaclysmBlacksmithSolid *solid, uint32_t face);

/**
 * The face whose id is `id`, or `CADACLYSM_BLACKSMITH_NONE` where no face has it (an
 * untracked solid, an id 0, a face a verb deleted) -- with no `last_error`; with it, for
 * a null solid.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_face_with_id(const struct CadaclysmBlacksmithSolid *solid,
                                           uint64_t id);

/**
 * How many input faces face `face` came from: 0 for a face the verb generated (a
 * fillet's round, a cut face) or an untracked solid, 1 for most, more for a face merged
 * from several. `CADACLYSM_BLACKSMITH_NONE` and `last_error` for a face the solid does
 * not have or a null solid.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_face_origin_count(const struct CadaclysmBlacksmithSolid *solid,
                                                uint32_t face);

/**
 * Origin `i` of face `face`: the operand it came from (its index in the verb's operand
 * order, as each verb's doc gives it) into `operand`, and that input face's id into
 * `id`. The first origin is the one the face lies on most. `false` and `last_error` for
 * a bad face, an `i` not below the count, or a null argument.
 *
 * # Safety
 * `solid` live; `operand` one `uint32_t`, `id` one `uint64_t`.
 */
bool cadaclysm_blacksmith_face_origin_at(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t face,
                                         uint32_t i,
                                         uint32_t *operand,
                                         uint64_t *id);

/**
 * Edge `edge`'s id, `edge` an index into the edge table (what
 * [`cadaclysm_blacksmith_edge`] and `fillet` take). As [`cadaclysm_blacksmith_face_id`]:
 * 0 where untracked; 0 and `last_error` for an edge past the table or a null solid.
 *
 * # Safety
 * `solid` live.
 */
uint64_t cadaclysm_blacksmith_edge_id(const struct CadaclysmBlacksmithSolid *solid, uint32_t edge);

/**
 * The edge-table index of the edge whose id is `id`, or `CADACLYSM_BLACKSMITH_NONE`, as
 * [`cadaclysm_blacksmith_face_with_id`].
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_edge_with_id(const struct CadaclysmBlacksmithSolid *solid,
                                           uint64_t id);

/**
 * How many input edges edge `edge` came from: 0 for a new edge, else 1 (edge merges are
 * not seen). As [`cadaclysm_blacksmith_face_origin_count`] otherwise.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_edge_origin_count(const struct CadaclysmBlacksmithSolid *solid,
                                                uint32_t edge);

/**
 * Origin `i` of edge `edge`, as [`cadaclysm_blacksmith_face_origin_at`].
 *
 * # Safety
 * `solid` live; `operand` one `uint32_t`, `id` one `uint64_t`.
 */
bool cadaclysm_blacksmith_edge_origin_at(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t edge,
                                         uint32_t i,
                                         uint32_t *operand,
                                         uint64_t *id);

/**
 * `out`, made from `via` by a verb of one operand, with its face and edge origins read
 * through `via`'s: each origin `(0, id)` replaced by the origins `via`'s face (edge) `id`
 * has, in order, each named once. Its ids, attributes and geometry stay `out`'s. Two
 * steps then read as one: [`cadaclysm_blacksmith_merge_flush`](crate::cadaclysm_blacksmith_merge_flush)
 * after a join, read through the join, names the join's two inputs, as operands 0 and 1,
 * rather than the join's own faces -- what [`cadaclysm_blacksmith_history`] of the merge
 * against the join's inputs needs.
 *
 * A new solid; an untracked `out` comes back as it is. Null and `last_error` where `via`
 * is untracked while `out` is not, where an origin names an operand other than 0 or an id
 * no face (edge) of `via` has (`out` was not made from `via` alone), or for a null
 * argument.
 *
 * # Safety
 * `out` and `via` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_origins_through(const struct CadaclysmBlacksmithSolid *out,
                                                                      const struct CadaclysmBlacksmithSolid *via);

/**
 * `solid` with attribute `key` set to `value`, over any it had: a new solid, tracked if
 * `solid` was not (an attribute rides with the faces' ids). Attributes are text: keys
 * and values UTF-8, read up to their NUL. A solid's attributes go with it through every
 * verb (a verb's result takes its first operand's), and are written to STEP files as
 * user-defined attributes. Null and `last_error` for an empty key, text that is not
 * UTF-8, or a null argument.
 *
 * # Safety
 * `solid` live; `key` and `value` NUL-terminated strings.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const char *key,
                                                                     const char *value);

/**
 * `solid` without attribute `key`: a new solid, equal to `solid` where it had none.
 * Null and `last_error` for a null argument or a key that is not UTF-8.
 *
 * # Safety
 * `solid` live; `key` a NUL-terminated string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_without_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const char *key);

/**
 * `solid`'s attribute `key`, or null where it has none (no `last_error`). Borrowed: it
 * lives as long as `solid` and must not be freed.
 *
 * # Safety
 * `solid` live; `key` a NUL-terminated string.
 */
const char *cadaclysm_blacksmith_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                           const char *key);

/**
 * How many attributes `solid` has. 0 (and `last_error`) for null.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_attribute_count(const struct CadaclysmBlacksmithSolid *solid);

/**
 * The key of `solid`'s attribute `i`, in key order (byte order). Borrowed: it lives as
 * long as `solid` and must not be freed. Null and `last_error` for an `i` not below the
 * count or a null solid.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_attribute_key_at(const struct CadaclysmBlacksmithSolid *solid,
                                                  uint32_t i);

/**
 * The value of `solid`'s attribute `i`, in key order. Borrowed: it lives as long as
 * `solid` and must not be freed. As [`cadaclysm_blacksmith_attribute_key_at`] otherwise.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_attribute_value_at(const struct CadaclysmBlacksmithSolid *solid,
                                                    uint32_t i);

/**
 * `solid` with face `face`'s attribute `key` set to `value`: a new solid, tracked if
 * `solid` was not. A face's attributes follow its id: kept with it through a verb, and
 * copied to every output face that names it as an origin (each piece of a split face
 * has its parent's). They stay in memory: no file carries them. Null and `last_error`
 * for a face the solid does not have, an empty key, text that is not UTF-8, or a null
 * argument.
 *
 * # Safety
 * `solid` live; `key` and `value` NUL-terminated strings.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_face_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                                                          uint32_t face,
                                                                          const char *key,
                                                                          const char *value);

/**
 * `solid` without face `face`'s attribute `key`: a new solid, equal to `solid` where the
 * face had none. Null and `last_error` for a face the solid does not have, a key that is
 * not UTF-8, or a null argument.
 *
 * # Safety
 * `solid` live; `key` a NUL-terminated string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_without_face_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                                                             uint32_t face,
                                                                             const char *key);

/**
 * Face `face`'s attribute `key`, or null where it has none (no `last_error`). Borrowed:
 * it lives as long as `solid` and must not be freed. Null and `last_error` for a face
 * the solid does not have or a null argument.
 *
 * # Safety
 * `solid` live; `key` a NUL-terminated string.
 */
const char *cadaclysm_blacksmith_face_attribute(const struct CadaclysmBlacksmithSolid *solid,
                                                uint32_t face,
                                                const char *key);

/**
 * How many attributes face `face` has. `CADACLYSM_BLACKSMITH_NONE` and `last_error` for
 * a face the solid does not have or a null solid.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_face_attribute_count(const struct CadaclysmBlacksmithSolid *solid,
                                                   uint32_t face);

/**
 * The key of face `face`'s attribute `i`, in key order (byte order). Borrowed: it lives
 * as long as `solid` and must not be freed. Null and `last_error` for a bad face, an `i`
 * not below the count, or a null solid.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_face_attribute_key_at(const struct CadaclysmBlacksmithSolid *solid,
                                                       uint32_t face,
                                                       uint32_t i);

/**
 * The value of face `face`'s attribute `i`, in key order. Borrowed: it lives as long as
 * `solid` and must not be freed. As [`cadaclysm_blacksmith_face_attribute_key_at`]
 * otherwise.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_face_attribute_value_at(const struct CadaclysmBlacksmithSolid *solid,
                                                         uint32_t face,
                                                         uint32_t i);

/**
 * The history of `out`, made by a verb from `inputs` (`count` solids, in the verb's
 * operand order, as each verb's "Marks:" line gives it), read off `out`'s ids and
 * origins alone. Inputs are named (operand, id), operand the index into `inputs`; every
 * list is in (operand, id) order, `generated` in id order:
 *
 * - **kept**: an input that became exactly one output, keeping its id -- (input, output
 *   id);
 * - **modified**: an input split (several outputs name it), merged (its output has other
 *   origins too) or renumbered (a later operand's id taken, a cut's bore) -- (input,
 *   outputs);
 * - **generated**: outputs with no origin (a fillet's round, the faces a split cuts);
 * - **deleted**: inputs no output names (a cut tool's caps).
 *
 * Null and `last_error` where `out` or an input is untracked (`"history: input 1 is not
 * tracked"`), an origin names an operand past `count`, or an argument is null. Free the
 * handle with [`cadaclysm_blacksmith_history_free`].
 *
 * # Safety
 * `out` live; `inputs` `count` live solids.
 */
struct CadaclysmBlacksmithHistory *cadaclysm_blacksmith_history(const struct CadaclysmBlacksmithSolid *out,
                                                                const struct CadaclysmBlacksmithSolid *const *inputs,
                                                                size_t count);

/**
 * [`cadaclysm_blacksmith_history`] for the edges, by edge id: each output edge has at
 * most one origin, so edge merges are not seen.
 *
 * # Safety
 * `out` live; `inputs` `count` live solids.
 */
struct CadaclysmBlacksmithHistory *cadaclysm_blacksmith_edge_history(const struct CadaclysmBlacksmithSolid *out,
                                                                     const struct CadaclysmBlacksmithSolid *const *inputs,
                                                                     size_t count);

/**
 * Release a history. Null is a no-op.
 *
 * # Safety
 * `history` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_history_free(struct CadaclysmBlacksmithHistory *history);

/**
 * How many inputs were kept. 0 (and `last_error`) for null.
 *
 * # Safety
 * `history` live.
 */
uint32_t cadaclysm_blacksmith_history_kept_count(const struct CadaclysmBlacksmithHistory *history);

/**
 * Kept input `i`: its operand and id into `operand` and `id`, and the output's id (the
 * same id) into `out_id`. `false` and `last_error` for an `i` not below the count or a
 * null argument.
 *
 * # Safety
 * `history` live; `operand` one `uint32_t`, `id` and `out_id` one `uint64_t` each.
 */
bool cadaclysm_blacksmith_history_kept_at(const struct CadaclysmBlacksmithHistory *history,
                                          uint32_t i,
                                          uint32_t *operand,
                                          uint64_t *id,
                                          uint64_t *out_id);

/**
 * How many inputs were modified. 0 (and `last_error`) for null.
 *
 * # Safety
 * `history` live.
 */
uint32_t cadaclysm_blacksmith_history_modified_count(const struct CadaclysmBlacksmithHistory *history);

/**
 * Modified input `i`: its operand and id into `operand` and `id`; its outputs through
 * [`cadaclysm_blacksmith_history_modified_output_count`] and `_output_at`. `false` and
 * `last_error` for an `i` not below the count or a null argument.
 *
 * # Safety
 * `history` live; `operand` one `uint32_t`, `id` one `uint64_t`.
 */
bool cadaclysm_blacksmith_history_modified_at(const struct CadaclysmBlacksmithHistory *history,
                                              uint32_t i,
                                              uint32_t *operand,
                                              uint64_t *id);

/**
 * How many outputs modified input `i` became (in output face order: a split's first
 * piece, which keeps the id, first). `CADACLYSM_BLACKSMITH_NONE` and `last_error` for an
 * `i` not below the count or a null history.
 *
 * # Safety
 * `history` live.
 */
uint32_t cadaclysm_blacksmith_history_modified_output_count(const struct CadaclysmBlacksmithHistory *history,
                                                            uint32_t i);

/**
 * The id of output `j` of modified input `i`. 0 and `last_error` for an `i` or `j` past
 * its list or a null history.
 *
 * # Safety
 * `history` live.
 */
uint64_t cadaclysm_blacksmith_history_modified_output_at(const struct CadaclysmBlacksmithHistory *history,
                                                         uint32_t i,
                                                         uint32_t j);

/**
 * How many outputs were generated. 0 (and `last_error`) for null.
 *
 * # Safety
 * `history` live.
 */
uint32_t cadaclysm_blacksmith_history_generated_count(const struct CadaclysmBlacksmithHistory *history);

/**
 * The id of generated output `i`, in id order. 0 and `last_error` for an `i` not below
 * the count or a null history.
 *
 * # Safety
 * `history` live.
 */
uint64_t cadaclysm_blacksmith_history_generated_at(const struct CadaclysmBlacksmithHistory *history,
                                                   uint32_t i);

/**
 * How many inputs were deleted. 0 (and `last_error`) for null.
 *
 * # Safety
 * `history` live.
 */
uint32_t cadaclysm_blacksmith_history_deleted_count(const struct CadaclysmBlacksmithHistory *history);

/**
 * Deleted input `i`: its operand and id into `operand` and `id`. `false` and
 * `last_error` for an `i` not below the count or a null argument.
 *
 * # Safety
 * `history` live; `operand` one `uint32_t`, `id` one `uint64_t`.
 */
bool cadaclysm_blacksmith_history_deleted_at(const struct CadaclysmBlacksmithHistory *history,
                                             uint32_t i,
                                             uint32_t *operand,
                                             uint64_t *id);

/**
 * Measure `solid` to a relative `accuracy`, into `out`. `false` and `last_error` if it cannot be
 * measured; `accuracy` of 0 or less asks for the default, a part in ten million.
 *
 * The body need not be one we built: `cadaclysm_blacksmith_from_brep` takes the brep a read file
 * hands out through `cadaclysm_node_brep`, so anything the reader opens can be measured here.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithMassProperties`.
 */
bool cadaclysm_blacksmith_mass_properties(const struct CadaclysmBlacksmithSolid *solid,
                                          double accuracy,
                                          struct CadaclysmBlacksmithMassProperties *out);

/**
 * `solid`'s box on its principal axes, to a relative `accuracy`, into `out`. `false` and
 * `last_error` for an open body, which has no principal axes, a NaN or infinite `accuracy`, a null
 * solid or a null `out`.
 *
 * 0 or less asks for the box's **own** default, `1e-5` -- not `measure.default_accuracy`. The box
 * costs a mass-properties integration at its accuracy, tens of seconds at 1e-7 on free-form bodies
 * read from files, and a finer accuracy buys little box for it: the half extents are grown by
 * `diag · max(accuracy, τ/16)`, `τ` the tolerance the integration settled on, which starts at
 * `5e-4 · diag` -- so a body that settles at once (planes, cylinders, cones) is grown by about
 * `3.1e-5 · diag` however fine the accuracy asked.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithOrientedBox`.
 */
bool cadaclysm_blacksmith_oriented_box(const struct CadaclysmBlacksmithSolid *solid,
                                       double accuracy,
                                       struct CadaclysmBlacksmithOrientedBox *out);

/**
 * The length of edge `edge` of `solid` (the index `cadaclysm_blacksmith_edge` and `fillet` use),
 * over the parameter range its `edge_curve` row reports, to a relative `accuracy` in (0, 1) (0 or
 * less asks for the default, `measure.default_accuracy`).
 *
 * `false` and `last_error` for a null solid or a null `out`; an index past the end of the table
 * (`cadaclysm_blacksmith_edge_count`), which leaves out the edges with no exact curve, so a body read
 * with 2D-only trims, as from Rhino or IGES, may list none; an edge with no exact curve; and an
 * `accuracy` that is NaN, infinite, or 1 or more (outside the length contract, refused rather than
 * clamped).
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithLength`.
 */
bool cadaclysm_blacksmith_edge_length(const struct CadaclysmBlacksmithSolid *solid,
                                      uint32_t edge,
                                      double accuracy,
                                      struct CadaclysmBlacksmithLength *out);

/**
 * The perimeter of `profile`'s outer loop -- holes are not counted -- to a relative `accuracy` in
 * (0, 1) (0 or less asks for the default, `measure.default_accuracy`). `false` and `last_error` for a
 * null profile, a null `out`, and an `accuracy` that is NaN, infinite, or 1 or more (refused rather
 * than clamped).
 *
 * # Safety
 * `profile` live; `out` one `CadaclysmBlacksmithLength`.
 */
bool cadaclysm_blacksmith_profile_length(const struct CadaclysmBlacksmithProfile *profile,
                                         double accuracy,
                                         struct CadaclysmBlacksmithLength *out);

/**
 * The closest points between the boundaries of `a` and `b`, to the absolute `tolerance` (positive
 * and finite, or unset), into `out` -- see `CadaclysmBlacksmithClosest` for what the
 * figures promise. `false` and `last_error` for a null solid or `out`, a tolerance that is
 * negative or infinite, or a body that meshes to nothing; `out` is untouched then.
 *
 * Reports `meshing`, `pruning` and `refining` to `progress` if not null. Curved bodies about equally
 * far apart everywhere (a ball nested in a ball) cost seconds at a tolerance of 1e-3, and quadratically
 * less at a coarser one.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a`, `b` live solids; `out` one `CadaclysmBlacksmithClosest`; `progress` null or a valid callback.
 */
bool cadaclysm_blacksmith_closest(const struct CadaclysmBlacksmithSolid *a,
                                  const struct CadaclysmBlacksmithSolid *b,
                                  double tolerance,
                                  CadaclysmBlacksmithProgress progress,
                                  void *user,
                                  struct CadaclysmBlacksmithClosest *out);

/**
 * `a` and `b` merged into one solid that keeps every piece: the regions of the result are
 * `a` less `b`, `a` and `b` together, and `b` less `a` (those that are not empty), and the walls
 * between them are faces of both. Faces keep the colours of the faces they are pieces of.
 *
 * Built exactly, so both solids must be closed and every face a plane, cylinder, cone, sphere or
 * torus; walls of the two that lie on one another in part are a case it refuses. Null and
 * `last_error` (`merge: ...`) for those, a null solid, and a `tolerance` negative or infinite.
 * `progress` is called as `cadaclysm_blacksmith_join` calls it.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a`, `b` live solids; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge(const struct CadaclysmBlacksmithSolid *a,
                                                            const struct CadaclysmBlacksmithSolid *b,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

/**
 * The regions of space `solid`'s faces bound, region 0 the infinite one: two for an ordinary
 * solid (outside, inside), one per cell for a merge's. Null and `last_error` (`regions: ...`) for
 * a null solid and a body whose regions cannot be read.
 *
 * # Safety
 * `solid` live. Free the list with `cadaclysm_blacksmith_regions_free`.
 */
struct CadaclysmBlacksmithRegions *cadaclysm_blacksmith_regions(const struct CadaclysmBlacksmithSolid *solid);

/**
 * How many regions. 0 (and `last_error`) for null.
 *
 * # Safety
 * `regions` live.
 */
uint32_t cadaclysm_blacksmith_regions_count(const struct CadaclysmBlacksmithRegions *regions);

/**
 * Region `i` into `out`. `false` (and `last_error`) for a null `regions`, a null `out`, or `i`
 * not below the count.
 *
 * # Safety
 * `regions` live; `out` one `CadaclysmBlacksmithRegion`.
 */
bool cadaclysm_blacksmith_regions_at(const struct CadaclysmBlacksmithRegions *regions,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithRegion *out);

/**
 * Side `k` of region `i` into `out`, the sides ascending by face then sense (-1 first).
 * `false` (and `last_error`) for a null `regions`, a null `out`, `i` not below the count, or
 * `k` not below the region's `sides`.
 *
 * # Safety
 * `regions` live; `out` one `CadaclysmBlacksmithFaceSide`.
 */
bool cadaclysm_blacksmith_regions_side_at(const struct CadaclysmBlacksmithRegions *regions,
                                          uint32_t i,
                                          uint32_t k,
                                          struct CadaclysmBlacksmithFaceSide *out);

/**
 * Release a regions list. Null is a no-op.
 *
 * # Safety
 * `regions` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_regions_free(struct CadaclysmBlacksmithRegions *regions);

/**
 * Finite region `region` of `solid` (an index into `cadaclysm_blacksmith_regions`' list) as a
 * closed solid of its own: the faces bounding it, each turned to point out of it, each keeping
 * its colour. A merge's cells come out one at a time this way, ready for the mass and the
 * booleans. Null and `last_error` for a null solid, region 0 (`region_solid: region 0 is the
 * infinite region`) and a region past the count.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_region_solid(const struct CadaclysmBlacksmithSolid *solid,
                                                                   uint32_t region);

/**
 * A curve from `count` control points (`xyz`, three doubles each) of `degree` (1 to 7), with
 * `weights` (one per point, positive; NULL for a plain B-spline) and the full knot vector
 * (`knot_count = count + degree + 1` values, non-decreasing; NULL for clamped and uniform).
 *
 * # Safety
 * `xyz` holds `3 * count` doubles; `weights` `count` or is NULL; `knots` `knot_count` or is NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_new(const double *xyz,
                                                                           size_t count,
                                                                           const double *weights,
                                                                           uint32_t degree,
                                                                           const double *knots,
                                                                           size_t knot_count);

/**
 * The curve of `degree` (1 to 7) through `count` points in order, chord-length parametrised.
 * `closed` closes it back to the first point, smooth across the seam (`C^(degree-1)`); an open
 * curve may leave along `start` and arrive along `end` (directions, any length; NULL for free).
 *
 * # Safety
 * `xyz` holds `3 * count` doubles; `start`, `end` three doubles each or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_through(const double *xyz,
                                                                               size_t count,
                                                                               uint32_t degree,
                                                                               bool closed,
                                                                               const double *start,
                                                                               const double *end);

/**
 * A curve of `degree` within `tolerance` of `count` points, through the first and the last
 * (least squares); the largest distance from a point to it is written to `error_out` when that
 * is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `xyz` holds `3 * count` doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fit(const double *xyz,
                                                                           size_t count,
                                                                           uint32_t degree,
                                                                           double tolerance,
                                                                           double *error_out);

/**
 * Edge `edge` of `solid` (the index `cadaclysm_blacksmith_edge_curve` takes) as an exact NURBS
 * over the edge's own span of its curve, running the way the edge's segments run.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_edge(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 uint32_t edge);

/**
 * The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `along_u`, else
 * along `v` at `u = at`. NURBS faces only.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(const struct CadaclysmBlacksmithSolid *solid,
                                                                                          uint32_t face,
                                                                                          bool along_u,
                                                                                          double at);

/**
 * The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end when
 * `b_end`, else its start): `continuity` 1 matches position and tangent (a cubic), 2 also the
 * curvature (a quintic). `bulge` (positive; 1 is usual) scales how far the tangents reach.
 *
 * # Safety
 * `a`, `b` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_blend(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                                             bool a_end,
                                                                             const struct CadaclysmBlacksmithNurbsCurve *b,
                                                                             bool b_end,
                                                                             uint32_t continuity,
                                                                             double bulge);

/**
 * `curve` projected onto the plane through `origin` with `normal`, along `direction` (NULL: the
 * normal). Exact: the control points move, the weights stay.
 *
 * # Safety
 * `curve` live; `origin`, `normal` three doubles; `direction` three doubles or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_plane(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                          const double *origin,
                                                                                          const double *normal,
                                                                                          const double *direction);

/**
 * `curve` projected along `direction` onto face `face` of `solid` (its whole surface), fitted
 * within `tolerance`; the largest distance between the result and the surface goes to
 * `error_out` when that is not NULL. Refused where a point's ray misses the surface.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve`, `solid` live; `direction` three doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_face(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                         const struct CadaclysmBlacksmithSolid *solid,
                                                                                         uint32_t face,
                                                                                         const double *direction,
                                                                                         double tolerance,
                                                                                         double *error_out);

/**
 * `curve`, lying on `solid` (a sheet: any of its faces, within ten times `tolerance`), offset
 * `distance` measured along the sheet square to it -- to the left of its run seen from the side
 * the faces' normals point to for positive, to the right for negative -- walked along the
 * surface across shared edges and fitted within `tolerance`; where it crosses a crease between
 * two faces, fitted each side and joined there. The largest distance between the result and
 * the sheet goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve`, `solid` live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                       const struct CadaclysmBlacksmithSolid *solid,
                                                                                       double distance,
                                                                                       double tolerance,
                                                                                       double *error_out);

/**
 * `curve` pulled onto face `face` of `solid` (its whole surface): every point to its nearest
 * surface point, fitted within `tolerance`; the error to `error_out` as for the projection.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve`, `solid` live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_pulled_to_face(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                      const struct CadaclysmBlacksmithSolid *solid,
                                                                                      uint32_t face,
                                                                                      double tolerance,
                                                                                      double *error_out);

/**
 * `curve` run the other way over the same domain.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_reversed(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * The part of `curve` from `t0` to `t1` (`t0 < t1`, both inside its domain), over `t0..t1`.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_trimmed(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                               double t0,
                                                                               double t1);

/**
 * `curve` continued `length` past its start (`at_start`) or end along its own end polynomial --
 * position, tangent and curvature there unchanged; every old parameter keeps its point.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_extended(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                bool at_start,
                                                                                double length);

/**
 * The same curve at degree `degree + by` (the result's degree at most 12).
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_elevated(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                uint32_t by);

/**
 * `count` curves joined end to end into one (Rhino's JoinCurves): in the order given, each
 * turned where needed so its start meets the previous one's end (the first too, when only its
 * start meets the second) within `tolerance`, the joint placed at the midpoint of the two
 * ends. All are raised to the highest degree among them and each runs over `[k, k + 1]`,
 * joined C0 (a corner stays a corner); a rational curve keeps its points. One curve gives a
 * copy; none, or a gap past `tolerance` (named in `last_error`), gives NULL.
 *
 * # Safety
 * `curves` holds `count` live curves.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_joined(const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                              size_t count,
                                                                              double tolerance);

/**
 * `count` curves blending evenly from `a` to `b` (Rhino's CreateTweenCurves family), tween `i`
 * at the fraction `(i + 1) / (count + 1)`, written to `out[i]` (owned: free each with
 * `cadaclysm_blacksmith_nurbs_curve_free`). `method` 0 is plain: control point by control
 * point, the curves of one structure (degree, control-point count, knots) or refused. 1 is
 * matching: made compatible exactly (degree elevation, knot merging), blended in homogeneous
 * coordinates. 2 is sampling: both divided by arc length into `samples` pieces (read only
 * here), a cubic interpolated through the blended samples. `align` turns `b`, and moves a
 * closed one's seam, to line it up with `a` first (Rhino's calls leave that to the caller).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * `false` and `last_error` for a null curve or `out`, a `count` of 0, an unknown `method`, one
 * curve closed and the other open, plain on curves that are not compatible, and too few
 * samples; nothing is written to `out` then.
 *
 * # Safety
 * `a`, `b` live; `out` holds `count` pointers.
 */
bool cadaclysm_blacksmith_nurbs_curve_tween(const struct CadaclysmBlacksmithNurbsCurve *a,
                                            const struct CadaclysmBlacksmithNurbsCurve *b,
                                            uint32_t count,
                                            uint32_t method,
                                            uint32_t samples,
                                            bool align,
                                            double tolerance,
                                            struct CadaclysmBlacksmithNurbsCurve **out);

/**
 * `curve` through the affine map `matrix` (16 doubles, row-major): its control points mapped,
 * its weights and knots kept -- exact. A singular map is allowed (a curve flattened onto a
 * plane is still a curve).
 *
 * # Safety
 * `curve` live; `matrix` 16 readable doubles.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_transformed(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                   const double *matrix);

/**
 * A copy of `curve`, freed on its own.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_clone(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * Release a curve. NULL is a no-op.
 *
 * # Safety
 * `curve` from this library, not yet freed.
 */
void cadaclysm_blacksmith_nurbs_curve_free(struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * The curve's degree; 0 (and `last_error`) for a NULL curve.
 *
 * # Safety
 * `curve` live or NULL.
 */
uint32_t cadaclysm_blacksmith_nurbs_curve_degree(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * How many control points the curve has; 0 (and `last_error`) for a NULL curve.
 *
 * # Safety
 * `curve` live or NULL.
 */
uint32_t cadaclysm_blacksmith_nurbs_curve_control_count(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * How many knots the curve's full knot vector has (`control_count + degree + 1`).
 *
 * # Safety
 * `curve` live or NULL.
 */
uint32_t cadaclysm_blacksmith_nurbs_curve_knot_count(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * The control points into `xyz` (`3 * control_count` doubles).
 *
 * # Safety
 * `curve` live; `xyz` room for `3 * control_count` doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_control_points(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                     double *xyz);

/**
 * The weights into `w` (`control_count` doubles; all 1 for a plain B-spline).
 *
 * # Safety
 * `curve` live; `w` room for `control_count` doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_weights(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                              double *w);

/**
 * The full knot vector into `k` (`knot_count` doubles).
 *
 * # Safety
 * `curve` live; `k` room for `knot_count` doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_knots(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                            double *k);

/**
 * Whether the curve's weights differ (a true NURBS rather than a plain B-spline).
 *
 * # Safety
 * `curve` live or NULL (false).
 */
bool cadaclysm_blacksmith_nurbs_curve_is_rational(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * Whether the curve ends where it starts (to `1e-10` of its size).
 *
 * # Safety
 * `curve` live or NULL (false).
 */
bool cadaclysm_blacksmith_nurbs_curve_is_closed(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * The parameter domain into `out[0..2]`.
 *
 * # Safety
 * `curve` live; `out` two doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_domain(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                             double *out);

/**
 * The point at parameter `t` (inside the domain) into `out[0..3]`.
 *
 * # Safety
 * `curve` live; `out` three doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_point(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                            double t,
                                            double *out);

/**
 * The point and its derivatives at `t` up to `order` (at most 8) into `out`: `C, C', C'', ...`,
 * three doubles each (`3 * (order + 1)` in all).
 *
 * # Safety
 * `curve` live; `out` room for `3 * (order + 1)` doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_derivatives(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                  double t,
                                                  uint32_t order,
                                                  double *out);

/**
 * The curvature and Frenet frame at `t` into `out`. Refused where the curve has no tangent.
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithCurvature`.
 */
bool cadaclysm_blacksmith_nurbs_curve_curvature(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                double t,
                                                struct CadaclysmBlacksmithCurvature *out);

/**
 * The curve's length to a relative `accuracy` (0 or less: the default) into `out`.
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithLength`.
 */
bool cadaclysm_blacksmith_nurbs_curve_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                             double accuracy,
                                             struct CadaclysmBlacksmithLength *out);

/**
 * The point at arc length `s` from the curve's start into `out` (`segment` NONE).
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithAt`.
 */
bool cadaclysm_blacksmith_nurbs_curve_point_at_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                      double s,
                                                      double accuracy,
                                                      struct CadaclysmBlacksmithAt *out);

/**
 * The curve in `n` pieces of equal arc length: `n + 1` samples, or `n` for a closed curve.
 *
 * # Safety
 * `curve` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_count(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                    uint32_t n,
                                                                                    double accuracy);

/**
 * Samples every `step` of arc length from the curve's start; a closed curve never repeats it.
 *
 * # Safety
 * `curve` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                     double step,
                                                                                     double accuracy);

/**
 * Where the curve crosses the plane through `origin` with `normal`, in parameter order: each an
 * `At` (point, unit tangent, parameter; `error` the point's distance from the plane). Refused
 * for a curve lying in the plane; a touch that does not cross is not listed.
 *
 * # Safety
 * `curve` live; `origin`, `normal` three doubles. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_plane_hits(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                               const double *origin,
                                                                               const double *normal);

/**
 * Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance` of it,
 * in parameter order (`error` each point's distance from the surface). A touch that does not
 * cross is not listed.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve`, `solid` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_face_hits(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                              const struct CadaclysmBlacksmithSolid *solid,
                                                                              uint32_t face,
                                                                              double tolerance);

/**
 * The sheet lofted through `count` section curves (`loose`: shaped by them, passing only the
 * first and last), `degree` across them (lowered to fit), periodic across them when `closed`
 * (the last section back to the first). One face on one NURBS surface.
 *
 * # Safety
 * `sections` holds `count` live curves.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_curves(const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                  size_t count,
                                                                  uint32_t degree,
                                                                  bool loose,
                                                                  bool closed);

/**
 * `count` sections swept along `rail`, each carried by the rail's frame from the rail point
 * nearest its centre and blended between: `frame` 0 rotation-minimising, 1 keeping `up` (three
 * doubles) upright. Fitted within `tolerance`; the error reached to `error_out` when not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `rail` live; `sections` holds `count` live curves; `up` three doubles or NULL; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_rail(const struct CadaclysmBlacksmithNurbsCurve *rail,
                                                                 const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                 size_t count,
                                                                 uint32_t frame,
                                                                 const double *up,
                                                                 double tolerance,
                                                                 double *error_out);

/**
 * `count` sections swept between `rail_a` and `rail_b`: each section's first end on rail a and
 * last on rail b, carried by the rotation and uniform scale that keep them there, the rails
 * matched by arc length. Fitted within `tolerance`; the error to `error_out` when not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `rail_a`, `rail_b` live; `sections` holds `count` live curves; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_two_rails(const struct CadaclysmBlacksmithNurbsCurve *rail_a,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *rail_b,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *const *sections,
                                                                      size_t count,
                                                                      double tolerance,
                                                                      double *error_out);

/**
 * The Coons sheet of 2, 3 or 4 boundary curves meeting end to end (in order round the
 * boundary, each either way round) within `tolerance`; exact for non-rational boundaries,
 * rational ones fitted first (that error to `error_out` when not NULL).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curves` holds `count` live curves; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edge_surface(const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                   size_t count,
                                                                   double tolerance,
                                                                   double *error_out);

/**
 * The Gordon sheet of a curve network: `u_count` curves along `u` (in order across `v`) and
 * `v_count` along `v`, every `u` curve crossing every `v` curve within `tolerance`. The largest
 * distance from the sheet to the curves to `error_out` when not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `u_curves` holds `u_count` and `v_curves` `v_count` live curves; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_network_surface(const struct CadaclysmBlacksmithNurbsCurve *const *u_curves,
                                                                      size_t u_count,
                                                                      const struct CadaclysmBlacksmithNurbsCurve *const *v_curves,
                                                                      size_t v_count,
                                                                      double tolerance,
                                                                      double *error_out);

/**
 * How well face `face_a` of `a` meets face `face_b` of `b` along their sides (a side: 0 the
 * face's `u = 0` isocurve, 1 `u = 1`, 2 `v = 0`, 3 `v = 1`), from `samples` points along side
 * a (16 at fewest), into `out`. Both faces NURBS.
 *
 * # Safety
 * `a`, `b` live; `out` one `CadaclysmBlacksmithContinuity`.
 */
bool cadaclysm_blacksmith_continuity(const struct CadaclysmBlacksmithSolid *a,
                                     uint32_t face_a,
                                     uint32_t side_a,
                                     const struct CadaclysmBlacksmithSolid *b,
                                     uint32_t face_b,
                                     uint32_t side_b,
                                     uint32_t samples,
                                     struct CadaclysmBlacksmithContinuity *out);

/**
 * Face `face_a` of `a`, its side bent to meet face `face_b` of `b`'s side at G`level` (0
 * position, 1 tangent plane, 2 curvature), as a sheet of its own; the opposite side stays where
 * it was. Both faces non-rational NURBS.
 *
 * # Safety
 * `a`, `b` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_match_side(const struct CadaclysmBlacksmithSolid *a,
                                                                 uint32_t face_a,
                                                                 uint32_t side_a,
                                                                 const struct CadaclysmBlacksmithSolid *b,
                                                                 uint32_t face_b,
                                                                 uint32_t side_b,
                                                                 uint32_t level);

/**
 * A sheet spanning from face `face_a` of `a`'s side to face `face_b` of `b`'s, meeting each at
 * G`level` (1 or 2); `bulge` (positive, 1 usual) scales how far it leaves each edge along its
 * neighbour's tangent. Both faces non-rational NURBS.
 *
 * # Safety
 * `a`, `b` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_blend_sides(const struct CadaclysmBlacksmithSolid *a,
                                                                  uint32_t face_a,
                                                                  uint32_t side_a,
                                                                  const struct CadaclysmBlacksmithSolid *b,
                                                                  uint32_t face_b,
                                                                  uint32_t side_b,
                                                                  uint32_t level,
                                                                  double bulge);

/**
 * The N-sided patch filling the hole `count` (3 or more) boundaries bound, meeting end to end
 * within `tolerance`: N four-sided NURBS faces round a central point, one sheet, face `i`
 * meeting boundary `i`'s second half along its `v = 0` side and boundary `i + 1`'s first half
 * along its `u = 1` side, the faces G1 or G2 to each other. `bulge` (positive, 1 usual) scales
 * how far the patch leaves each neighbour along the neighbour's own tangent. The report to
 * `report_out` when not NULL. The patch declares the loosest tolerances its sheets declare.
 *
 * `tolerance` 0 or NaN: the sheets' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)),
 * or the curves' when every boundary is a curve.
 *
 * # Safety
 * `boundaries` holds `count` boundaries, each with a live `sheet` or, that NULL, a live
 * `curve`; `report_out` one `CadaclysmBlacksmithPatchReport` or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_n_sided_patch(const struct CadaclysmBlacksmithPatchBoundary *boundaries,
                                                                    size_t count,
                                                                    double bulge,
                                                                    double tolerance,
                                                                    struct CadaclysmBlacksmithPatchReport *report_out);

/**
 * The rolling-ball fillet between face `face_a` of `a` and face `face_b` of `b` (their whole
 * NURBS surfaces): the ball on the side of each face's normal (`flip_*`: the other side), its
 * radius `radius_start` at the fillet's first end running linearly to `radius_end` at its last,
 * fitted within `tolerance`. Returns the fillet sheet; the contact curves on each face are
 * written to `rail_a` / `rail_b` when those are not NULL (owned: free with
 * `cadaclysm_blacksmith_nurbs_curve_free`), the error reached to `error_out` when not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a`, `b` live; `rail_a`, `rail_b` one pointer each or NULL; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_surfaces(const struct CadaclysmBlacksmithSolid *a,
                                                                      uint32_t face_a,
                                                                      const struct CadaclysmBlacksmithSolid *b,
                                                                      uint32_t face_b,
                                                                      double radius_start,
                                                                      double radius_end,
                                                                      bool flip_a,
                                                                      bool flip_b,
                                                                      double tolerance,
                                                                      struct CadaclysmBlacksmithNurbsCurve **rail_a,
                                                                      struct CadaclysmBlacksmithNurbsCurve **rail_b,
                                                                      double *error_out);

/**
 * `sheet` cut along `curve` and nothing removed: every face comes back in its pieces outside
 * the cutter, then its pieces inside, each piece a face, in `sheet`'s face order. The cutter is
 * `curve` run along `direction` (three doubles; NULL for the mean of the sheet's normals along
 * the curve) through the whole sheet: a closed curve's inside is the island it bounds, an open
 * curve's the side left of its run seen from where `direction` points. An open curve is run on
 * straight past both ends, so it should cross the sheet's boundary or point at it. Where the
 * cut lies on `curve` (a curve drawn on the sheet) the rim is one edge carrying the curve's own
 * span exactly, its ends on the curve, which another sheet's edge along the curve sews to.
 * `tolerance` is the split's meshing tolerance.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `curve` live handles; `direction` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_curve(const struct CadaclysmBlacksmithSolid *sheet,
                                                                     const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                     const double *direction,
                                                                     double tolerance);

/**
 * `sheet` split along `curve`, a curve lying on it, with no direction to cut along: each face is
 * cut in its own parameters where the curve crosses it, so a cut across a sheet that rolls
 * away from any one view never glances off it. Nothing is removed: every face comes back as its
 * pieces, face by face, those left of the curve's run (seen from the faces' outward side)
 * first. A closed curve cuts an island; an open one must run off the sheet -- one stopping
 * short is carried on along the sheet along its end tangent. Where the cut lies on `curve` the
 * rim is one edge carrying the curve's own span exactly (a closed curve round on one face, two),
 * which another sheet's edge along the curve sews to. Refused where the curve stands off the
 * sheet by more than ten times `tolerance`, or a face of the sheet closes round on itself.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `curve` live handles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_along_curve(const struct CadaclysmBlacksmithSolid *sheet,
                                                                        const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                        double tolerance);

/**
 * `sheet` cut along `curve` (lying on it) into two panels with a shut line between them --
 * a car body's panel gap: each panel trimmed back `gap / 2` from the curve, measured along the
 * sheet, and given a flange on the edges it was cut back to (not the sheet's own edges): a
 * ruled face from the edge to the edge moved `flange` along the faces' outward normals,
 * negative turning it under for a sheet whose normals face out, 0 for none. Where the curve
 * runs off the sheet each flange ends square at its panel's corner. The panel left of the
 * curve's run (seen from the faces' outward side) goes to `out[0]`, the right one to `out[1]`;
 * a loop run counter-clockwise from that side has the island on its left. Works across the
 * faces of a joined sheet. `true` on success; `false` and `last_error` otherwise, nothing
 * written to `out`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `curve` live handles; `out` holds two pointers.
 */
bool cadaclysm_blacksmith_panel_gap(const struct CadaclysmBlacksmithSolid *sheet,
                                    const struct CadaclysmBlacksmithNurbsCurve *curve,
                                    double gap,
                                    double flange,
                                    double tolerance,
                                    struct CadaclysmBlacksmithSolid **out);

/**
 * `sheet` cut along `curve` and one side thrown away: `keep_inside` true keeps the island a
 * closed curve bounds (the side left of an open curve's run), false the rest -- a hole cut, or
 * the other side. See [`cadaclysm_blacksmith_split_by_curve`]. Refused where nothing of the
 * sheet lies on the kept side.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `curve` live handles; `direction` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim_by_curve(const struct CadaclysmBlacksmithSolid *sheet,
                                                                    const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                    const double *direction,
                                                                    bool keep_inside,
                                                                    double tolerance);

/**
 * `sheet` with an opening recessed into it -- a window, a lamp, a grille or an intake set into
 * a panel. `outline` is a closed curve on the sheet (one face or several joined); each of its
 * points is found on the sheet, so it may stand a little off it. The sheet is cut along it and
 * walls run back `depth` along the sheet's own normal at every point of the rim (positive behind
 * the face, against its normal; negative in front), leaning in toward the opening by `draft`
 * radians as they go (negative: out; within 75 degrees), the walls meeting on the mitre at the
 * outline's corners. `fillet` above 0 rounds the rim between the sheet and the walls with a ball
 * of that radius (the outline must then be smooth, and the fillet shallower than the walls).
 * `pane` closes the back with one patch whose four sides end where the outline turns most -- a
 * rectangle's corners, the middle of a rounded rectangle's corner arcs -- so it does not twist.
 * Every piece is sewn to the next: one body, its faces in order -- the sheet's, the fillet's, the
 * walls', the pane's -- with only the sheet's own boundary naked, and the walls' foot without a
 * pane. `faces_out`, when not NULL, gets those four face counts. `tolerance` is the fits', the
 * cut's and the sewing's. Refused for an outline that is not closed, a corner with a fillet, a
 * fillet deeper than the walls, and a sheet the outline cannot be found on.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `outline` live handles; `faces_out` four `uint32_t` or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_recess(const struct CadaclysmBlacksmithSolid *sheet,
                                                             const struct CadaclysmBlacksmithNurbsCurve *outline,
                                                             double depth,
                                                             double draft,
                                                             double fillet,
                                                             bool pane,
                                                             double tolerance,
                                                             uint32_t *faces_out);

/**
 * `count` sheets joined into one body, their faces in order: every two naked edges whose ends
 * and curves agree within `tolerance` (0 or NaN: a rounding of the body's size, or the
 * loosest absolute tolerance the sheets declare where that is larger) sewn into one edge --
 * a gap closed is kept as that edge's own tolerance -- the faces turned to agree across their
 * edges, and a closed result turned to face out, a solid the booleans, the measures and the
 * writers take. Edges that carry exact curves are compared to the tolerance however coarsely
 * each was sampled. What was done is written to `report` when it is not NULL. At a tolerance
 * above 0 a T-junction is sewn too: one sheet's edge along part of another's is first cut where
 * the other's corner lies on it, and its pieces are sewn. Refused for no sheets, a negative or
 * infinite tolerance, and faces that cannot be turned to agree (a one-sided surface).
 *
 * # Safety
 * `sheets` holds `count` live solids; `report` one `CadaclysmBlacksmithJoinReport` or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join_sheets(const struct CadaclysmBlacksmithSolid *const *sheets,
                                                                  size_t count,
                                                                  double tolerance,
                                                                  struct CadaclysmBlacksmithJoinReport *report);

/**
 * `section` swept along each of the `count` naked `edges` of `sheet` (indices into the list
 * [`cadaclysm_blacksmith_edge`](crate::cadaclysm_blacksmith_edge) walks) on the face's own frame:
 * at every point of the edge the section's `x` runs outward from the face (square to the edge,
 * in the face's tangent plane) and its `y` along the face's normal, so `(0, 0) -> (0, -10)`
 * turns the edge under by 10 all along it however the face curves. `section` is a curve in the
 * plane `z = 0` starting at the origin. The sweeps are sewn to `sheet` when `join` (the sheet's
 * faces first, then one per edge), else returned alone, sewn to each other. Each sweep is
 * fitted within `tolerance`; the largest error to `error_out` when not NULL. Refused for no
 * edges, an edge given twice, out of range, bordered by two faces or without an exact curve, a
 * section not starting at the origin, and sweeps the join did not sew on.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `section` live handles; `edges` `count` indices; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_flange(const struct CadaclysmBlacksmithSolid *sheet,
                                                             const uint32_t *edges,
                                                             size_t count,
                                                             const struct CadaclysmBlacksmithNurbsCurve *section,
                                                             double tolerance,
                                                             bool join,
                                                             double *error_out);

/**
 * Each of the `count` naked `edges` of `sheet` (indices into the list
 * [`cadaclysm_blacksmith_edge`](crate::cadaclysm_blacksmith_edge) walks) slid along `direction`
 * (three doubles) until it meets `target`: every point of the edge travels along the direction
 * to its first hit on `target`'s faces. One wall per edge -- the edge's own curve swept straight,
 * bounded by the curve through the hits, fitted within `tolerance` of every hit (the largest
 * distance to `error_out` when not NULL). Sewn to `sheet` when `join` (the sheet's faces first,
 * then one per edge), else returned alone, sewn to each other. Refused as `flange` is, and for a
 * direction of no length, a point whose line misses the target (named) and an edge touching it.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `sheet`, `target` live handles; `edges` `count` indices; `direction` three doubles; `error_out`
 * one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_to(const struct CadaclysmBlacksmithSolid *sheet,
                                                                 const uint32_t *edges,
                                                                 size_t count,
                                                                 const double *direction,
                                                                 const struct CadaclysmBlacksmithSolid *target,
                                                                 double tolerance,
                                                                 bool join,
                                                                 double *error_out);

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
 * scope=server plan=startup servers=1` -- or, without one, `unlicensed`
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
 * again at a *different* tolerance, by this thread or any other: callers on
 * several threads at one tolerance share one mesh, meshed once. Faces are meshed watertight, vertices
 * welded by position. All-null and `last_error` on failure. For arrays that must outlive a
 * re-mesh or the solid, hold the tessellation: [`cadaclysm_blacksmith_tessellation`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithMesh cadaclysm_blacksmith_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                         double tolerance);

/**
 * [`cadaclysm_blacksmith_mesh`] in `double`, from the same cache, under the same rule:
 * valid until the solid is freed or meshed again at a different tolerance. For arrays that
 * must outlive a re-mesh or the solid, hold the tessellation: [`cadaclysm_blacksmith_tessellation`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_mesh64(const struct CadaclysmBlacksmithSolid *solid,
                                                             double tolerance);

/**
 * The triangles each face contributed to the mesh [`cadaclysm_blacksmith_mesh`]
 * gives at the same `tolerance`: one count per face in face order, summing to
 * that mesh's `index_count / 3`. The mesher writes a face's triangles together
 * and the faces in order, so face `f`'s triangles are the `counts[f]` that
 * follow the first `sum(counts[..f])`; a face that meshed to nothing counts
 * zero. What a viewer colours a face by. Same cache and lifetime rule as the
 * mesh. Null `counts` and `last_error` on failure. For arrays that must outlive a re-mesh or
 * the solid, hold the tessellation: [`cadaclysm_blacksmith_tessellation`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_mesh_face_triangles(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 double tolerance);

/**
 * The feature edges the mesher locked at `tolerance`, as polylines that lie on
 * the mesh [`cadaclysm_blacksmith_mesh`] gives at the same tolerance. Same
 * cache and lifetime rule as the mesh. For arrays that must outlive a re-mesh or the solid,
 * hold the tessellation: [`cadaclysm_blacksmith_tessellation`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(const struct CadaclysmBlacksmithSolid *solid,
                                                                        double tolerance);

/**
 * The solid meshed at `tolerance`, held: the same mesh [`cadaclysm_blacksmith_mesh`] lends at
 * that tolerance (the very same arrays while the solid's cache holds it), owned by the handle
 * rather than lent by the solid. Where the solid's own arrays last until it is freed or meshed
 * again at another tolerance, these last until [`cadaclysm_blacksmith_tessellation_free`],
 * whatever happens to the solid. The solid still keeps one tessellation: a replaced one lives
 * exactly as long as a handle holds it. Null, with
 * [`cadaclysm_blacksmith_last_error`](crate::cadaclysm_blacksmith_last_error) saying why, for a
 * null solid or a tolerance that is negative or infinite.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithTessellation *cadaclysm_blacksmith_tessellation(const struct CadaclysmBlacksmithSolid *solid,
                                                                          double tolerance);

/**
 * Free a held tessellation, and with it every array lent from it. Null is a no-op.
 *
 * # Safety
 * `tessellation` null, or from [`cadaclysm_blacksmith_tessellation`] and not freed already.
 */
void cadaclysm_blacksmith_tessellation_free(struct CadaclysmBlacksmithTessellation *tessellation);

/**
 * The held mesh's triangles, as [`cadaclysm_blacksmith_mesh`] gives them, borrowed from the
 * handle and good until [`cadaclysm_blacksmith_tessellation_free`]. All-null and `last_error`
 * for a null handle.
 *
 * # Safety
 * `tessellation` null or live.
 */
struct CadaclysmBlacksmithMesh cadaclysm_blacksmith_tessellation_mesh(const struct CadaclysmBlacksmithTessellation *tessellation);

/**
 * The held mesh's triangles in `double`, as [`cadaclysm_blacksmith_mesh64`] gives them,
 * borrowed from the handle and good until [`cadaclysm_blacksmith_tessellation_free`]. All-null
 * and `last_error` for a null handle.
 *
 * # Safety
 * `tessellation` null or live.
 */
struct CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_tessellation_mesh64(const struct CadaclysmBlacksmithTessellation *tessellation);

/**
 * The held mesh's per-face triangle counts, as [`cadaclysm_blacksmith_mesh_face_triangles`]
 * gives them, borrowed from the handle and good until
 * [`cadaclysm_blacksmith_tessellation_free`]. Null `counts` and `last_error` for a null handle.
 *
 * # Safety
 * `tessellation` null or live.
 */
struct CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_tessellation_face_triangles(const struct CadaclysmBlacksmithTessellation *tessellation);

/**
 * The held mesh's feature-edge polylines, as [`cadaclysm_blacksmith_edge_polylines`] gives
 * them, borrowed from the handle and good until [`cadaclysm_blacksmith_tessellation_free`].
 * All-null and `last_error` for a null handle.
 *
 * # Safety
 * `tessellation` null or live.
 */
struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_tessellation_edge_polylines(const struct CadaclysmBlacksmithTessellation *tessellation);

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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithColours cadaclysm_blacksmith_edge_polyline_colours(const struct CadaclysmBlacksmithSolid *solid,
                                                                             double tolerance);

/**
 * A colour per exact edge of [`cadaclysm_blacksmith_gpu_surfaces`] at the same
 * `tolerance`: `count` equals that record's Bezier count (`edges_len / 16`), and
 * Bezier `i` draws in `rgb[3 * i .. 3 * i + 3]` -- its edge's own colour, else the
 * solid's edge colour, else `-1, -1, -1` (none: the viewer's own). What a viewer
 * drawing the exact edges paints them with, as it paints
 * [`cadaclysm_blacksmith_edge_polylines`] with
 * [`cadaclysm_blacksmith_edge_polyline_colours`]. No edge paint, a bad tolerance or
 * argument: as that call. Same cache and lifetime rule as the mesh.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithColours cadaclysm_blacksmith_gpu_edge_colours(const struct CadaclysmBlacksmithSolid *solid,
                                                                        double tolerance);

/**
 * The outline, then each hole, as polylines at z = 0, within `tolerance` of its
 * arcs and splines: a closed loop repeats its first point at the end; an open
 * chain (a profile ended open) is the segments it has. What a viewer draws a
 * profile with. The arrays belong to the profile and stay valid until it is
 * freed: each tolerance asked is flattened once and kept, so asking again at
 * another tolerance -- on this thread or any other -- never moves or frees
 * arrays already handed out. Safe to call on one profile from several threads
 * at once; a profile asked at many distinct tolerances holds that many copies
 * of its outline until it is freed.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `min`, `max` three doubles each.
 */
bool cadaclysm_blacksmith_bounds(const struct CadaclysmBlacksmithSolid *solid,
                                 double tolerance,
                                 double *min,
                                 double *max);

/**
 * [`cadaclysm_blacksmith_bounds`] in `double`, from the same tessellation's unnarrowed
 * positions: exact far from the origin, where `bounds`' widened `f32` positions are not.
 * `false` on a null solid or a non-positive, non-finite tolerance.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `min`, `max` three doubles each.
 */
bool cadaclysm_blacksmith_bounds64(const struct CadaclysmBlacksmithSolid *solid,
                                   double tolerance,
                                   double *min,
                                   double *max);

/**
 * The solid's axis-aligned box, in `double`, at a cost that does not grow with the
 * solid's size: its mesh at a tolerance of a thousandth of its own extent, so the box
 * is inside the exact one and short of it by at most that. What a wrapper's `bounds`
 * reads. [`cadaclysm_blacksmith_bounds`] meshes at a tolerance the caller names --
 * an absolute one, which on a part tens of metres long in millimetres is millions of
 * triangles. Worked out once per solid, and apart from the tessellation `mesh` and
 * `bounds` share: asking it never invalidates their arrays. `false` on a null solid
 * or null output.
 *
 * # Safety
 * `solid` live; `min`, `max` three doubles each.
 */
bool cadaclysm_blacksmith_box(const struct CadaclysmBlacksmithSolid *solid,
                              double *min,
                              double *max);

/**
 * `count` solids as one STEP part file, each its own `MANIFOLD_SOLID_BREP`,
 * through `cadaclysm_step_ap::write_breps_coloured`. `schema` is NULL for the
 * built-in AP203 (`CONFIG_CONTROL_DESIGN`) -- or AP242 when any solid, face or edge is
 * coloured, since AP203's first edition has no entity to state a colour with -- the name of a built-in schema
 * (`AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF`, …; case-insensitive) --
 * a built-in schema must carry every entity the writer emits, as AP203 and
 * AP242 do and AP214's `AUTOMOTIVE_DESIGN` does not -- or the EXPRESS source
 * text of a custom schema. A solid's, its faces' and its edges' colours are written
 * as STEP styling (`STYLED_ITEM` over `COLOUR_RGB`) under a schema that has it, and
 * left out under a named one that does not. `unit` 0 = metre, 1 = millimetre, 2 = inch, and
 * says what the solids' lengths are. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * Set the kernel option `step.validation_properties` to 1
 * ([`cadaclysm_blacksmith_option_set`]) and every body also carries its **geometric
 * validation properties**: the surface area, the volume and the centroid this kernel
 * measures for it, stated in the file so the kernel that reads it can check the
 * transfer against its own measurement of the same geometry. They are measured at
 * `step.validation_accuracy` (1e-5) and stated in the file's own length unit, and the
 * file keeps everything it would otherwise carry -- its product name, its attributes,
 * its colours, its material. With no schema named the default moves to AP242 then, as a
 * colour moves it; a named schema that cannot state the properties is refused rather
 * than written without the figures asked for. A body whose measurement is refused is
 * written **without** properties and the file is still written: this call returns one
 * string and has no room for a per-body report, so a caller who needs to know which
 * bodies were measured asks [`cadaclysm_blacksmith_mass_properties`] itself. The
 * figures are as good as the accuracy asked for and no better -- STEP has no field for
 * an error bound.
 *
 * # Safety
 * `solids` `count` live solids; `schema` NULL or a NUL-terminated string.
 */
char *cadaclysm_blacksmith_step(const struct CadaclysmBlacksmithSolid *const *solids,
                                size_t count,
                                const char *schema,
                                uint32_t unit);

/**
 * An assembly as one STEP file, through `cadaclysm_step_ap::write_assembly`: each of
 * the `part_count` parts -- `solids[i]`, named `names[i]` -- written once as its own
 * product, in its own coordinates; each of the `placement_count` placements an
 * occurrence of part `parts_of[k]` at the frame `frames[12 * k ..]` (origin, x, y,
 * z, as every frame argument; right-handed and orthonormal), all under one root
 * product, `assembly`. A reader tessellates a part once however many times it is
 * placed. A part no placement names is not written. `schema` and `unit` as for
 * [`cadaclysm_blacksmith_step`]. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure -- a
 * placement naming no part or at a frame a STEP placement cannot state included.
 *
 * **The option `step.validation_properties` does nothing here**: an assembly file
 * carries no validation properties however it is set. OpenCascade states even a single
 * solid's figures on a `SHAPE_ASPECT` of that body's own shape rather than on the
 * `PRODUCT_DEFINITION` a part's material hangs from, so assemblies are deferred to a
 * follow-up rather than half-written; stamp a part file
 * ([`cadaclysm_blacksmith_step`]) to get them.
 *
 * # Safety
 * `solids` and `names` `part_count` entries each (live solids, NUL-terminated
 * UTF-8 names); `parts_of` `placement_count` indices; `frames` `12 * placement_count`
 * doubles; `schema` NULL or a NUL-terminated string.
 */
char *cadaclysm_blacksmith_step_assembly(const struct CadaclysmBlacksmithSolid *const *solids,
                                         const char *const *names,
                                         size_t part_count,
                                         const uint32_t *parts_of,
                                         const double *frames,
                                         size_t placement_count,
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
 * `count` solids as one Rhino `.3dm` (version 8, which Rhino 8 and 9 open), one
 * object each, through `cadaclysm_rhino3dm::write`: each an `ON_Brep` with its exact
 * surfaces and trims, or -- where a body has no exact form there -- its mesh. Each
 * object is named as its solid is, coloured with the solid's own colour (a face's or
 * an edge's own colour has no place in a `.3dm` object and is left out), and carries
 * the solid's attributes as user text. `unit` is as for [`cadaclysm_blacksmith_step`]
 * and is the file's unit: the numbers written are the numbers held.
 *
 * The bytes are owned, their count written through `len`: release them with
 * [`cadaclysm_blacksmith_bytes_free`], passing the same `len` back. Null and
 * `last_error` on failure. On success `last_error` lists, one line each, what was
 * written as a mesh or left out (`solid 1: written as a mesh: ...`), or is null
 * where everything was written as itself.
 *
 * # Safety
 * `solids` `count` live solids; `len` a writable `size_t`.
 */
uint8_t *cadaclysm_blacksmith_3dm_bytes(const struct CadaclysmBlacksmithSolid *const *solids,
                                        size_t count,
                                        uint32_t unit,
                                        size_t *len);

/**
 * [`cadaclysm_blacksmith_3dm_bytes`] written to `path`, replacing any file there.
 * `false` and `last_error` on failure, including the file's; on success
 * `last_error` says what was written as a mesh or left out, as that call's does.
 *
 * # Safety
 * `solids` `count` live solids; `path` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_3dm(const struct CadaclysmBlacksmithSolid *const *solids,
                              size_t count,
                              const char *path,
                              uint32_t unit);

/**
 * Release bytes this library handed over as owned ([`cadaclysm_blacksmith_3dm_bytes`],
 * [`cadaclysm_blacksmith_assembly_3dm_bytes`]). Null is a no-op. `len` must be the
 * length that same call wrote through its own `len` -- the bytes carry no NUL or
 * length of their own to read it back from.
 *
 * # Safety
 * `bytes` null, or exactly what one of those calls returned and not yet freed, with
 * `len` that call's own out-written length.
 */
void cadaclysm_blacksmith_bytes_free(uint8_t *bytes, size_t len);

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
 * edges one unit wide on nothing, and each solid's outline beside them.
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
 * `solid_count` solids and `profile_count` profiles as one SVG wireframe: a
 * `<g id="solid-<i>">` per solid then a `<g id="profile-<i>">` per profile,
 * on one page, each stroked in its own colour where it carries one and in the
 * options' `stroke` otherwise. Either count may be 0 -- a drawing of solids
 * alone is [`cadaclysm_blacksmith_svg_text`], which is this with no profiles
 * -- and both 0 is refused. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `solid_count` live solids or null when the count is 0; `profiles`
 * likewise; `options` a struct filled by
 * [`cadaclysm_blacksmith_svg_options_init`].
 */
char *cadaclysm_blacksmith_drawing_svg_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                            size_t solid_count,
                                            const struct CadaclysmBlacksmithProfile *const *profiles,
                                            size_t profile_count,
                                            const struct CadaclysmBlacksmithSvgOptions *options);

/**
 * [`cadaclysm_blacksmith_drawing_svg_text`] written to `path`, replacing any
 * file there. `false` and `last_error` on failure, the file's included.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_drawing_svg_text`]; `path` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_drawing_svg(const struct CadaclysmBlacksmithSolid *const *solids,
                                      size_t solid_count,
                                      const struct CadaclysmBlacksmithProfile *const *profiles,
                                      size_t profile_count,
                                      const char *path,
                                      const struct CadaclysmBlacksmithSvgOptions *options);

/**
 * A solid's silhouette curves as rational cubic Béziers, flattened to an
 * owned buffer of doubles: per segment, its four control points' `x, y, z`
 * (12 numbers) then its four weights (4 numbers) -- `*count * 16` doubles in
 * all. `count` is written through the out-parameter either way (0 on a
 * refusal or on an answer with none).
 *
 * The eye comes from the same options [`cadaclysm_blacksmith_svg_text`]
 * draws with (`up`, `azimuth`, `elevation`, `fov`, and `tolerance`/`width`
 * read together as a world tolerance), so a caller drawing a picture and
 * asking for its outline gets one eye, not two. A body with no silhouette --
 * every face planar, like a cube's, since a plane never turns away from any eye
 * -- is not an error: null, `count` 0, and an empty `last_error`. Every call
 * that runs under this library's `guard` -- which is every call that builds,
 * reads or writes geometry -- clears the error slot before it does anything
 * else, and this one does too, except for a null `count`: that is refused
 * (`silhouette: null count`, nothing allocated) before the guard runs, so it
 * sets its message without clearing first. Past that check, null with an empty
 * slot is the empty answer and null with a message is a refusal, whatever an
 * earlier call left behind. The calls that do not run under the guard, and so
 * never clear the slot, are the frees (`..._free`), the struct-fill
 * initialisers (`..._svg_options_init`, `..._fem_options_init`), the pure
 * accessors (`..._version`, `..._license_info`, `..._license_notice_count`,
 * `..._build_date`, `..._brep_layout_id`), `..._license_set` (which sets a
 * message of its own on a refusal) and the error getter itself.
 *
 * Owned, unlike the reader library's borrowed `cadaclysm_node_silhouette_beziers`:
 * every handle this library hands out is already the caller's to free (see the
 * module doc, "Handles are immutable"), so this follows that convention rather
 * than the reader's borrowed slot. Free a non-null result with
 * [`cadaclysm_blacksmith_silhouette_beziers_free`], passing back the same
 * `count` this call wrote -- the buffer carries no length of its own, unlike a
 * string's NUL.
 *
 * # Safety
 * `solid` null or live; `options` null or a struct filled by
 * [`cadaclysm_blacksmith_svg_options_init`]; `count` a writable `u32`.
 */
double *cadaclysm_blacksmith_silhouette_beziers(const struct CadaclysmBlacksmithSolid *solid,
                                                const struct CadaclysmBlacksmithSvgOptions *options,
                                                uint32_t *count);

/**
 * Release what [`cadaclysm_blacksmith_silhouette_beziers`] handed out. Null
 * is a no-op. `count` must be the value that same call wrote through its own
 * out-parameter -- unlike the strings [`cadaclysm_blacksmith_string_free`]
 * releases, this buffer carries no NUL or length of its own to read it back
 * from.
 *
 * # Safety
 * `data` must be null, or exactly what
 * [`cadaclysm_blacksmith_silhouette_beziers`] returned and not yet freed,
 * with `count` that same call's own out-written count.
 */
void cadaclysm_blacksmith_silhouette_beziers_free(double *data, uint32_t count);

/**
 * A solid's exact faces packed for a GPU surface evaluator, and its exact edges: the record
 * the reader's `cadaclysm_node_gpu_surfaces` hands out for a part, for this solid.
 *
 * `faces` is the faces this GPU path can express, in the solid's face order -- the order
 * [`cadaclysm_blacksmith_mesh_face_triangles`] counts in, but not necessarily every one of
 * them: a face with no area is left out, so `face_count` can be below
 * [`cadaclysm_blacksmith_face_count`](crate::cadaclysm_blacksmith_face_count)'s answer for the
 * same solid. A caller pairing this record with `mesh_face_triangles`' per-face counts must
 * check the two counts agree before zipping them by index; they need not, and a mismatch means
 * some faces were dropped, not reordered.
 *
 * Free with [`cadaclysm_blacksmith_gpu_surfaces_free`]. NULL, with `last_error`, for a null
 * solid, a tolerance that is not a positive finite number, or a solid with no exact faces.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithGpuSurfaces *cadaclysm_blacksmith_gpu_surfaces(const struct CadaclysmBlacksmithSolid *solid,
                                                                         double tolerance);

/**
 * Frees what [`cadaclysm_blacksmith_gpu_surfaces`] handed out. NULL is allowed.
 *
 * # Safety
 * `surfaces` null or a result of [`cadaclysm_blacksmith_gpu_surfaces`] not yet freed.
 */
void cadaclysm_blacksmith_gpu_surfaces_free(struct CadaclysmBlacksmithGpuSurfaces *surfaces);

/**
 * Release a string this library handed over as owned (`cadaclysm_blacksmith_step`,
 * `cadaclysm_blacksmith_step_assembly`, `cadaclysm_blacksmith_sat_text`,
 * `cadaclysm_blacksmith_brep_text`, `cadaclysm_blacksmith_svg_text`,
 * `cadaclysm_blacksmith_drawing_svg_text`, `cadaclysm_blacksmith_fem_mesh_msh_text`,
 * `cadaclysm_blacksmith_assembly_place_solid`, `cadaclysm_blacksmith_assembly_place_assembly`,
 * `cadaclysm_blacksmith_assembly_step`, and every text `cadaclysm_blacksmith_document_*` returns:
 * `_save`, `_apply`, `_preview`, `_end_preview`, `_batch_end`, `_batch_abort`, `_undo`, `_redo`,
 * `_params`, `_evaluate`, `_result_kind`, `_value`, `_errors`, `_kinds`, `_branch_new`,
 * `_branch_switch`, `_tips`, `_branch_list`, `_log`).
 * Null is a no-op. A `.3dm`'s bytes are not a string: [`cadaclysm_blacksmith_bytes_free`]
 * releases those.
 *
 * **This list is the whole of it, and it is where a caller comes to find out whether a
 * pointer is theirs to free.** A text from anywhere else in this library is borrowed and must
 * not be passed here -- and the reverse mistake costs just as much: the reader library's
 * `cadaclysm_fem_mesh_msh_text` borrows from its handle, so a caller holding both libraries
 * frees the kernel's `.msh` text and not the reader's.
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
 * A regular polygon of `sides` sides (3 to 1000000) on the circle of `radius`
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
 * A regular polygon of `sides` sides (3 to 1000000) whose sides touch the circle
 * of `radius` about (`cx`, `cy`) -- the polygon across flats, a nut's hex: its
 * corners on the circle of `radius / cos(π / sides)`, the first at `angle`
 * radians from the sketch's x axis, the rest counter-clockwise, on the same
 * rays as `cadaclysm_blacksmith_profile_regular_polygon`'s corners with the
 * same `angle`; each side's midpoint on the circle of `radius`.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circumscribed_polygon(double cx,
                                                                                      double cy,
                                                                                      double radius,
                                                                                      uint32_t sides,
                                                                                      double angle);

/**
 * A star of `points` tips (3 to 1000000) on the circle of `outer` about
 * (`cx`, `cy`), its inner corners on the circle of `inner` (positive, under
 * `outer`), alternating: the first tip at `angle` radians from the sketch's x
 * axis, the rest counter-clockwise, each inner corner half a step on from the
 * tip before it -- `2 * points` straight sides.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_star(double cx,
                                                                     double cy,
                                                                     double outer,
                                                                     double inner,
                                                                     uint32_t points,
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
 * negative or infinite tolerance, a piece empty, with holes or closed on
 * its own, or a piece that meets none of the others -- named by its index.
 * The pieces are untouched.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * A conic arc to (`x`, `y`) through the control point (`cx`, `cy`) with middle
 * weight `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the
 * rational quadratic Bezier, kept exact. Refused for a weight not positive and finite,
 * an end on the current point, or a control point on the chord.
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_conic_to(struct CadaclysmBlacksmithPath *p,
                                        double x,
                                        double y,
                                        double cx,
                                        double cy,
                                        double weight);

/**
 * The parabolic arc to (`x`, `y`) whose vertex is (`vx`, `vy`): the axis and focal
 * length are solved from the two ends. Refused when the vertex lies on the chord or
 * no parabola with that vertex passes through both ends (the vertex must be the arc's
 * extreme point).
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_parabola_by_vertex(struct CadaclysmBlacksmithPath *p,
                                                  double x,
                                                  double y,
                                                  double vx,
                                                  double vy);

/**
 * The parabolic arc to (`x`, `y`) whose focus is (`fx`, `fy`); of the two parabolas
 * through the ends with that focus, the one whose vertex lies between the ends'
 * projections, then the one whose arc cups the focus (the focus between the arc and
 * its chord), then the more symmetric; with the focus beyond the chord that is the
 * arch over the ends, not the shallow dish -- draw that one with
 * [`cadaclysm_blacksmith_path_parabola`].
 * Refused when the focus lies on the chord or is an end.
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_parabola_by_focus(struct CadaclysmBlacksmithPath *p,
                                                 double x,
                                                 double y,
                                                 double fx,
                                                 double fy);

/**
 * Start an outline on the arc of the parabola with vertex (`vx`, `vy`), axis
 * direction (`ax`, `ay`) and focal length `focal`, over the across-axis coordinates
 * `from..to` (`from < to`): the path begins at the arc's first point and holds the
 * arc as one conic segment -- a reflector from rim to rim. Null (and `last_error`)
 * for a zero axis, a focal length not positive and finite, or `from >= to`. Free it
 * with [`cadaclysm_blacksmith_path_free`] if it is never ended.
 */
struct CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_parabola(double vx,
                                                                   double vy,
                                                                   double ax,
                                                                   double ay,
                                                                   double focal,
                                                                   double from,
                                                                   double to);

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
 * `text` (UTF-8) set in a font, one profile per closed shape -- a letter with
 * its counters as holes (`o` one, `8` two; `i` is two profiles) -- on the
 * sketch plane, the baseline along x from the origin, each outline
 * counter-clockwise and its holes clockwise, a curved side the font's own
 * cubic Bezier kept exactly. `size` is roughly the height of a capital.
 * `font` is a family, optionally with a style (`"Liberation Sans:style=Bold"`),
 * a font file's path, or null/empty for the bundled Liberation Sans Regular,
 * which also serves when the family is not found; `font_bytes` (`font_len` of
 * them, or null) a font file's bytes, used instead of `font` when given.
 * `halign` is `"left"`, `"center"` or `"right"` (null: left); `valign`
 * `"baseline"`, `"bottom"`, `"center"` or `"top"` (null: baseline); `spacing`
 * multiplies the gap between glyphs (1 as the font has it); `direction`
 * `"ltr"` or `"rtl"` (null: ltr). Empty text is a list with a count of 0.
 * Null (and `last_error`) for null text, a size or spacing not positive and
 * finite, an alignment or direction not one of those words, font bytes that
 * are not a font.
 *
 * # Safety
 * `text`, `font`, `halign`, `valign`, `direction` NUL-terminated or null;
 * `font_bytes` readable for `font_len` bytes or null.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_text(const char *text,
                                                                         double size,
                                                                         const char *font,
                                                                         const uint8_t *font_bytes,
                                                                         size_t font_len,
                                                                         const char *halign,
                                                                         const char *valign,
                                                                         double spacing,
                                                                         const char *direction);

/**
 * The region `a` and `b` share: zero or more profiles, each outer loop
 * counter-clockwise and each hole clockwise, arcs and splines kept exact. An
 * arc kept from an input can still come out split at that input's own seam
 * point (two circles' lens is four arcs, one pair per circle) -- exact, not
 * an approximation. Two loops of a result may touch at a point (two holes
 * whose corners meet, one from each input): a right point set that the verbs
 * needing simple loops -- extrude, a boolean taking it as an input -- refuse.
 * Both must be closed and simple. Null (and `last_error`) for a null profile,
 * a `tolerance` negative or infinite, an open or self-crossing profile, a
 * `tolerance` too fine for these profiles (following their arcs and splines to
 * a tenth of it would take more than 8 million points, about 128 MB), and, as
 * a defect rather than an outcome, a result that fails to close. No shared
 * area is a list with a count of 0.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a` and `b` live profiles.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_common(const struct CadaclysmBlacksmithProfile *a,
                                                                           const struct CadaclysmBlacksmithProfile *b,
                                                                           double tolerance);

/**
 * `p` with every free-form side (a Bezier, a conic, a NURBS) replaced by lines and
 * arcs within `tolerance` of it both ways round -- what a G-code writer can say.
 * Lines and arcs pass through as they are, every loop closes on itself exactly,
 * holes are converted the same way. Null (and `last_error`) for a null profile, a
 * `tolerance` negative or infinite, a spline that does not evaluate.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_to_arcs(const struct CadaclysmBlacksmithProfile *p,
                                                                        double tolerance);

/**
 * `p` grown by `distance` (shrunk where it is negative): zero or more profiles,
 * all lines and arcs, outward corners rounded by `|distance|`, holes moving against
 * the boundary. Free-form sides are fitted to `tolerance` first
 * ([`cadaclysm_blacksmith_profile_to_arcs`]). A shrink that eats the whole profile
 * is a list with a count of 0. Null (and `last_error`) for a null profile, a
 * `distance` not finite, a `tolerance` negative or infinite, a loop with no
 * sides, loops that cross or touch.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_offset(const struct CadaclysmBlacksmithProfile *p,
                                                                           double distance,
                                                                           double tolerance);

/**
 * `s` cut by the plane `Z = z`: its closed outlines there, in XY, nested into
 * profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
 * circle crossing kept exact. A plane that misses the solid is a list with a count
 * of 0. Null (and `last_error`) for a null solid, a `z` not finite, a `tolerance`
 * negative or infinite, a face lying in the plane (section a little above or
 * below it), a crossing that does not close.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `s` a live solid.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_solid_section(const struct CadaclysmBlacksmithSolid *s,
                                                                          double z,
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
 * under it), the one whose boundary comes nearest. Where no surface of that kind
 * passes through the point (the solid was resized), the faces of that kind facing the
 * same way at its projection: the only one, or the one clearly nearest the point.
 * `hint` is the index the face had,
 * preferred among faces that fit equally well (negative for none); `tolerance` how
 * far the point may sit off a surface to still be on it. -1 where the face is gone
 * (no `last_error`); -2 and `last_error` for a null solid or a malformed reference.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `face_ref` eight doubles.
 */
int32_t cadaclysm_blacksmith_find_face(const struct CadaclysmBlacksmithSolid *solid,
                                       const double *face_ref,
                                       int32_t hint,
                                       double tolerance);

/**
 * Edge `edge` of the edge table (what [`cadaclysm_blacksmith_edge`] and `fillet` index)
 * by what it is, fifteen doubles into `out`:
 *
 * | at | what |
 * |---|---|
 * | 0 | the curve's kind: line 0, circle 1, ellipse 2, parabola 3, hyperbola 4, NURBS 5, other 6 |
 * | 1-3 | the point at half its arc length (x y z) |
 * | 4-6 | the unit tangent there (x y z) |
 * | 7 | its length |
 * | 8-10 | the outward normal there of one face meeting on it (x y z) |
 * | 11-13 | the other's (an open sheet's rim: the one face's again; zero where unreadable) |
 * | 14 | its span: how far from the midpoint [`cadaclysm_blacksmith_find_edge`] may find it on a resized solid |
 *
 * A reference a feature made on the edge keeps, to find the edge again when the solid
 * has been rebuilt -- as [`cadaclysm_blacksmith_face_ref`] is for a face. Take it off the
 * solid before any move you apply to it. `false` and `last_error` for an edge past the
 * table, one with no length to measure, or a null argument.
 *
 * # Safety
 * `solid` live; `out` fifteen doubles.
 */
bool cadaclysm_blacksmith_edge_ref(const struct CadaclysmBlacksmithSolid *solid,
                                   uint32_t edge,
                                   double *out);

/**
 * The edge-table index of the edge of `solid` that `edge_ref` (fifteen doubles, as
 * [`cadaclysm_blacksmith_edge_ref`] lays them out) refers to: of the edges of that kind
 * passing within `tolerance` of the midpoint and running the same way (either sense),
 * the one of nearest length. Where none passes through it (the solid was resized), the
 * edge of that kind running the same way between faces facing the same two ways, the
 * only one or the one clearly nearest the midpoint, and no farther than the span. -1
 * where the edge is gone (no `last_error`) -- never whatever now sits at the old index;
 * -2 and `last_error` for a null argument, a malformed reference or a tolerance that is
 * not positive.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edge_ref` fifteen doubles.
 */
int32_t cadaclysm_blacksmith_find_edge(const struct CadaclysmBlacksmithSolid *solid,
                                       const double *edge_ref,
                                       double tolerance);

/**
 * How many vertices `solid` has: its edges' ends, welded, in the order
 * [`cadaclysm_blacksmith_vertex_ref`] and [`cadaclysm_blacksmith_find_vertex`] index.
 * 0 (and `last_error`) for null.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_vertex_count(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Vertex `vertex` by where it is, three doubles (x y z, in the solid's own coordinates)
 * into `out`. `false` and `last_error` for a vertex the solid does not have or a null
 * argument.
 *
 * # Safety
 * `solid` live; `out` three doubles.
 */
bool cadaclysm_blacksmith_vertex_ref(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t vertex,
                                     double *out);

/**
 * The vertex of `solid` nearest `vertex_ref` (three doubles, x y z) within `tolerance`.
 * A vertex reference may be any point, a picked one too, so there is no second tier:
 * -1 where no vertex is that near (no `last_error`); -2 and `last_error` as
 * [`cadaclysm_blacksmith_find_edge`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `vertex_ref` three doubles.
 */
int32_t cadaclysm_blacksmith_find_vertex(const struct CadaclysmBlacksmithSolid *solid,
                                         const double *vertex_ref,
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
 * radius` for a circle); a parabola's own parameter with `radius` its focal
 * length `F` (`point(t) = origin + x*F*t*t + y*2*F*t`, `radius2` 0); a
 * hyperbola's with `radius, radius2` its semi-axes `a, b` (`point(t) =
 * origin + x*a*cosh(t) + y*b*sinh(t)`); a NURBS's knot parameter (`knots[degree] <= t0 < t1
 * <= knots[n]`). Frame vectors `x, y, z` are unit for a conic; for a line
 * `x` is the direction with length equal to the line's own length and `y, z`
 * are zero. Always `t0 < t1`: an edge whose segments run against its curve's
 * own parameter reports the same range -- read the direction from the
 * edge's `segments`, not from the range.
 *
 * `kind` is one of "line", "circle", "ellipse", "parabola", "hyperbola" or
 * "nurbs" -- static, never freed. For a conic or a line `degree` is 0 and `knots`, `poles`, `weights`
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
 * How many edges of the solid's mesh at `tolerance` are bound by anything other
 * than exactly two triangles -- zero for a closed solid. The mesh is the one
 * [`cadaclysm_blacksmith_mesh`] and `cadaclysm_blacksmith_mesh_face_triangles`
 * hand out at that tolerance, read at its double-precision positions rather than
 * the `f32` arrays (whose precision falls off with a coordinate's magnitude, so a
 * solid far from the origin could weld a shared edge wrongly there). It comes from
 * the cache where that is at `tolerance`, and is meshed the same way where it is
 * not, without replacing the cache: arrays already lent out stay valid.
 *
 * It was once a full-quality mesh of its own, and the two can disagree: a
 * 64-section terrain loft meshed closed that way at 838,932 triangles, while the
 * mesh handed out came to 1,040,670 -- past the body's ceiling of a million -- with
 * its last five faces left empty and 3,672 open edges, reported as none. A face
 * the ceiling leaves empty opens every edge it shares with a face that meshed; a
 * whole shell left empty opens none, and shows only as zeros among the face
 * triangle counts.
 *
 * A hole (one triangle on an edge), a fold, and a seam two solids share along a
 * line (four triangles meeting on it) all count here;
 * [`cadaclysm_blacksmith_unpaired_edges`] is the check that lets the seam pass.
 * `CADACLYSM_BLACKSMITH_NONE` (and `last_error`) on a null solid or a
 * non-positive, non-finite tolerance.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * side of such a seam as of any other edge. Asked of the same mesh, at the
 * same precision, as [`cadaclysm_blacksmith_leaked_edges`]. Same failure shape as
 * [`cadaclysm_blacksmith_leaked_edges`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * An empty tree. Never null.
 */
struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_new(void);

/**
 * A tree over `n` entries at once, packed (sort-tile-recursive): fuller and faster to build than
 * the same entries inserted one by one. Entry `i` is `ids[i]` with the box `boxes[6 i..6 i + 6]`.
 * `n = 0` (the pointers may then be null) is an empty tree.
 *
 * Null and `last_error` for a null `ids` or `boxes` with `n` above 0, and the first entry whose
 * box is not a box, by index.
 *
 * # Safety
 * `ids` readable for `n` entries and `boxes` for `6 n`, or null with `n` 0.
 */
struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_boxes(const uint32_t *ids,
                                                                       const double *boxes,
                                                                       uint32_t n);

/**
 * A tree over `n` points (`xyz`, 3 doubles each), each a zero box whose id is its index. `n = 0`
 * (`xyz` may then be null) is an empty tree.
 *
 * Null and `last_error` for a null `xyz` with `n` above 0, and the first point with a NaN or
 * infinite coordinate, by index.
 *
 * # Safety
 * `xyz` readable for `3 n` doubles, or null with `n` 0.
 */
struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_points(const double *xyz,
                                                                        uint32_t n);

/**
 * A tree over a mesh's `n_triangles` triangles, `indices` 3 a triangle into the `n_points` points
 * `xyz` (3 doubles each): one entry per triangle, its id the triangle's index, its box its three
 * corners' box. `n_triangles = 0` (the pointers may then be null) is an empty tree.
 *
 * Null and `last_error` for a null `xyz` with `n_points` above 0 or a null `indices` with
 * `n_triangles` above 0, then the first corner past the points (`"rtree_from_triangles: triangle 1
 * names point 9 of 4"`) or at a point with a NaN or infinite coordinate, by triangle and point.
 * Points no triangle uses are not checked.
 *
 * # Safety
 * `xyz` readable for `3 n_points` doubles and `indices` for `3 n_triangles`, or null with their
 * count 0.
 */
struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_triangles(const double *xyz,
                                                                           uint32_t n_points,
                                                                           const uint32_t *indices,
                                                                           uint32_t n_triangles);

/**
 * A tree over `solid`'s faces: one entry per face, its id the face index the other face calls
 * use, its box holding the face (the box the boolean's broad phase pairs faces by, grown by a
 * thousandth of the solid's extent). A solid with no faces gives an empty tree.
 *
 * Null and `last_error` for a null solid, or a face that cannot be boxed.
 *
 * # Safety
 * `solid` live. Free the tree with `cadaclysm_blacksmith_rtree_free`.
 */
struct CadaclysmBlacksmithRTree *cadaclysm_blacksmith_solid_face_tree(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Add the entry `(id, box)`. `false` and `last_error` for a null tree or box, or a box that is
 * not a box; the tree is then left as it was.
 *
 * # Safety
 * `tree` live and not read by another thread meanwhile; `box_` 6 doubles.
 */
bool cadaclysm_blacksmith_rtree_insert(struct CadaclysmBlacksmithRTree *tree,
                                       uint32_t id,
                                       const double *box_);

/**
 * Add the entry `(id, p)`, the point as a zero box. `false` and `last_error` for a null tree or
 * point, or a point with a NaN or infinite coordinate.
 *
 * # Safety
 * `tree` live and not read by another thread meanwhile; `p` 3 doubles.
 */
bool cadaclysm_blacksmith_rtree_insert_point(struct CadaclysmBlacksmithRTree *tree,
                                             uint32_t id,
                                             const double *p);

/**
 * Take out one entry equal to `(id, box)` -- the box it was inserted with, compared per
 * coordinate (a point's is its zero box) -- and say whether there was one. With duplicates, one
 * goes per call.
 *
 * `false` with no error when there is no such entry; `false` and `last_error` for a null tree or
 * box, or a box that is not a box.
 *
 * # Safety
 * `tree` live and not read by another thread meanwhile; `box_` 6 doubles.
 */
bool cadaclysm_blacksmith_rtree_remove(struct CadaclysmBlacksmithRTree *tree,
                                       uint32_t id,
                                       const double *box_);

/**
 * How many entries `tree` holds. 0 (and `last_error`) for null.
 *
 * # Safety
 * `tree` live.
 */
uint32_t cadaclysm_blacksmith_rtree_count(const struct CadaclysmBlacksmithRTree *tree);

/**
 * The union of every entry's box into `out` (6 doubles). `false` and `last_error` for a null tree
 * or `out`, and for an empty tree, which has no bounds.
 *
 * # Safety
 * `tree` live; `out` 6 writable doubles.
 */
bool cadaclysm_blacksmith_rtree_bounds(const struct CadaclysmBlacksmithRTree *tree, double *out);

/**
 * Release a tree. Null is a no-op.
 *
 * # Safety
 * `tree` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_rtree_free(struct CadaclysmBlacksmithRTree *tree);

/**
 * The ids of every entry whose box meets `box` (touching counts), ascending, each with distance 0.
 * Null and `last_error` for a null tree or box, or a box that is not a box.
 *
 * # Safety
 * `tree` live; `box_` 6 doubles. Free the list with `cadaclysm_blacksmith_rtree_hits_free`.
 */
struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_search(const struct CadaclysmBlacksmithRTree *tree,
                                                                       const double *box_);

/**
 * Every entry whose box is within `r` of `p` (Euclidean, 0 inside the box; `r = 0` finds the
 * boxes holding `p`), by distance then id. Null and `last_error` for a null tree or point, a point
 * with a NaN or infinite coordinate, and a negative or NaN `r`.
 *
 * # Safety
 * `tree` live; `p` 3 doubles. Free the list with `cadaclysm_blacksmith_rtree_hits_free`.
 */
struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_within(const struct CadaclysmBlacksmithRTree *tree,
                                                                       const double *p,
                                                                       double r);

/**
 * The `k` entries whose boxes are nearest `p`, by distance then id (at equal distance the smaller
 * ids win): all of them when `k` is over the count, none for `k = 0`. Null and `last_error` for a
 * null tree or point, a point with a NaN or infinite coordinate, and `k` above 1 000 000.
 *
 * # Safety
 * `tree` live; `p` 3 doubles. Free the list with `cadaclysm_blacksmith_rtree_hits_free`.
 */
struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_nearest(const struct CadaclysmBlacksmithRTree *tree,
                                                                        const double *p,
                                                                        uint32_t k);

/**
 * Every entry whose box the ray `origin + t direction`, `0 <= t <= max_t`, meets, as hits whose
 * `distance` is the `t` where the ray enters the box (0 when `origin` is inside it), by `t` then
 * id. Touching counts: a ray grazing a face or an edge meets the box. `t` is in units of
 * `direction`'s length (it is not normalised); `max_t` may be `INFINITY`.
 *
 * Null and `last_error` for a null tree, origin or direction, an origin or direction with a NaN or
 * infinite coordinate, a zero direction (`"rtree_ray: direction (0, 0, 0) is not a direction"`),
 * and a NaN or negative `max_t` (`"rtree_ray: max_t -1 is not a distance"`).
 *
 * # Safety
 * `tree` live; `origin` and `direction` 3 doubles each. Free the list with
 * `cadaclysm_blacksmith_rtree_hits_free`.
 */
struct CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_ray(const struct CadaclysmBlacksmithRTree *tree,
                                                                    const double *origin,
                                                                    const double *direction,
                                                                    double max_t);

/**
 * How many hits. 0 (and `last_error`) for null.
 *
 * # Safety
 * `hits` live.
 */
uint32_t cadaclysm_blacksmith_rtree_hits_count(const struct CadaclysmBlacksmithRTreeHits *hits);

/**
 * Hit `i` into `out`. `false` (and `last_error`) for a null `hits`, a null `out`, or `i` not
 * below the count.
 *
 * # Safety
 * `hits` live; `out` one `CadaclysmBlacksmithRTreeHit`.
 */
bool cadaclysm_blacksmith_rtree_hits_at(const struct CadaclysmBlacksmithRTreeHits *hits,
                                        uint32_t i,
                                        struct CadaclysmBlacksmithRTreeHit *out);

/**
 * Release a hits list. Null is a no-op.
 *
 * # Safety
 * `hits` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_rtree_hits_free(struct CadaclysmBlacksmithRTreeHits *hits);

/**
 * Every pair `(a, b)` of an entry of `a` and one of `b` whose boxes are at most `slack` apart on
 * every axis -- they meet once each is grown by `slack / 2` on every side, so `slack = 0` is
 * touching -- ascending. `a` and `b` may be the same tree. Null and `last_error` for a null tree
 * and a negative or NaN `slack`.
 *
 * # Safety
 * `a` and `b` live. Free the list with `cadaclysm_blacksmith_rtree_pairs_free`.
 */
struct CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_overlaps(const struct CadaclysmBlacksmithRTree *a,
                                                                          const struct CadaclysmBlacksmithRTree *b,
                                                                          double slack);

/**
 * Every unordered pair of distinct entries of `tree` at most `slack` apart (as
 * [`cadaclysm_blacksmith_rtree_overlaps`]), once each as `(smaller id, larger id)`, ascending; an
 * id pairs with itself only where two entries share it. Null and `last_error` for a null tree and
 * a negative or NaN `slack`.
 *
 * # Safety
 * `tree` live. Free the list with `cadaclysm_blacksmith_rtree_pairs_free`.
 */
struct CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_self_overlaps(const struct CadaclysmBlacksmithRTree *tree,
                                                                               double slack);

/**
 * How many pairs. 0 (and `last_error`) for null.
 *
 * # Safety
 * `pairs` live.
 */
uint32_t cadaclysm_blacksmith_rtree_pairs_count(const struct CadaclysmBlacksmithRTreePairs *pairs);

/**
 * Pair `i` into `out`. `false` (and `last_error`) for a null `pairs`, a null `out`, or `i` not
 * below the count.
 *
 * # Safety
 * `pairs` live; `out` one `CadaclysmBlacksmithRTreePair`.
 */
bool cadaclysm_blacksmith_rtree_pairs_at(const struct CadaclysmBlacksmithRTreePairs *pairs,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithRTreePair *out);

/**
 * Release a pairs list. Null is a no-op.
 *
 * # Safety
 * `pairs` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_rtree_pairs_free(struct CadaclysmBlacksmithRTreePairs *pairs);

/**
 * A new, empty sketch. Free it with [`cadaclysm_blacksmith_sketch_free`].
 */
struct CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_new(void);

/**
 * Frees a sketch; null is a no-op.
 *
 * # Safety
 * `s` must be null or a sketch not yet freed.
 */
void cadaclysm_blacksmith_sketch_free(struct CadaclysmBlacksmithSketch *s);

/**
 * A sketch built from a profile: its lines, arcs and curves become entities
 * joined end to end, holes included. With `infer` true the obvious constraints
 * (horizontal, vertical, tangent joints, ...) are added too; `tolerance` is the
 * distance within which ends count as joined. Null on failure.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `profile` must be a live profile.
 */
struct CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_from_profile(const struct CadaclysmBlacksmithProfile *profile,
                                                                           bool infer,
                                                                           double tolerance);

/**
 * A free point at (`x`, `y`): its id, or `CADACLYSM_BLACKSMITH_NONE` (a coordinate
 * that is not finite).
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_point(struct CadaclysmBlacksmithSketch *s,
                                               double x,
                                               double y);

/**
 * A line between the points `a` and `b`: its id, or `CADACLYSM_BLACKSMITH_NONE`
 * (an unknown id, or `a == b`).
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_line(struct CadaclysmBlacksmithSketch *s,
                                              uint32_t a,
                                              uint32_t b);

/**
 * A circle of radius `r` about the point `centre`: its id, or
 * `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_circle(struct CadaclysmBlacksmithSketch *s,
                                                uint32_t centre,
                                                double r);

/**
 * A counter-clockwise arc about the point `centre` from the point `start` to the
 * point `end`: its id, or `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_arc(struct CadaclysmBlacksmithSketch *s,
                                             uint32_t centre,
                                             uint32_t start,
                                             uint32_t end);

/**
 * A cubic Bezier free curve from the point `start` through the controls (`c1x`,
 * `c1y`) and (`c2x`, `c2y`) to a new end point (`x`, `y`): its id, or
 * `CADACLYSM_BLACKSMITH_NONE`. The curve owns its control points.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_bezier(struct CadaclysmBlacksmithSketch *s,
                                                uint32_t start,
                                                double c1x,
                                                double c1y,
                                                double c2x,
                                                double c2y,
                                                double x,
                                                double y);

/**
 * A rational quadratic (conic) free curve from the point `start` with the control
 * (`cx`, `cy`) and weight `weight` to a new end point (`x`, `y`): its id, or
 * `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_add_conic(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t start,
                                               double cx,
                                               double cy,
                                               double x,
                                               double y,
                                               double weight);

/**
 * A NURBS free curve of `degree` from the point `start`. `xy` holds `count`
 * control points after the start as x, y pairs (`2 * count` doubles); `weights` is
 * null for a plain B-spline or holds `count + 1` weights (the start's first);
 * `knots` holds `knot_count` knot values. The id, or `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `s` must be a live sketch; the arrays must hold the counts given.
 */
uint32_t cadaclysm_blacksmith_sketch_add_nurbs(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t start,
                                               uint32_t degree,
                                               const double *xy,
                                               size_t count,
                                               const double *weights,
                                               const double *knots,
                                               size_t knot_count);

/**
 * The rectangle with corners (`x0`, `y0`) and (`x1`, `y1`): 8 ids, the four corners
 * counter-clockwise from (`x0`, `y0`) then the four sides (side `i` from corner `i`);
 * borrowed, `count` set to 8. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_add_rect(struct CadaclysmBlacksmithSketch *s,
                                                     double x0,
                                                     double y0,
                                                     double x1,
                                                     double y1,
                                                     size_t *count);

/**
 * The kind of entity `id`: one of the `CADACLYSM_BLACKSMITH_SKETCH_ENTITY_*` codes, or `CADACLYSM_BLACKSMITH_NONE` for an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_kind(const struct CadaclysmBlacksmithSketch *s,
                                          uint32_t id);

/**
 * The live entity ids, ascending; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_entities(struct CadaclysmBlacksmithSketch *s,
                                                     size_t *count);

/**
 * Writes the point `id`'s position to `out[0]`, `out[1]`. False if `id` is not a point.
 *
 * # Safety
 * `s` must be a live sketch; `out` room for 2 doubles.
 */
bool cadaclysm_blacksmith_sketch_point(const struct CadaclysmBlacksmithSketch *s,
                                       uint32_t id,
                                       double *out);

/**
 * Moves the point `id` to (`x`, `y`) without solving. False on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_set_point(struct CadaclysmBlacksmithSketch *s,
                                           uint32_t id,
                                           double x,
                                           double y);

/**
 * The radius of the circle or arc `id`; NaN on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
double cadaclysm_blacksmith_sketch_radius(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

/**
 * Sets the radius of the circle `id` to `r` without solving. False on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_set_radius(struct CadaclysmBlacksmithSketch *s,
                                            uint32_t id,
                                            double r);

/**
 * The centre point of the circle or arc `id`, or `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_centre(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

/**
 * The points an entity runs between: a line's `[a, b]`, an arc's `[start, end]`, a
 * free curve's `[start, controls..., end]`; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_ends(struct CadaclysmBlacksmithSketch *s,
                                                 uint32_t id,
                                                 size_t *count);

/**
 * Marks the entity `id` as construction geometry (helper geometry kept out of
 * profiles) or back. False on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_set_construction(struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id,
                                                  bool on);

/**
 * Whether the entity `id` is construction geometry; false for an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_is_construction(const struct CadaclysmBlacksmithSketch *s,
                                                 uint32_t id);

/**
 * Whether the entity `id` is a reference copy of another sketch's entity (see
 * `cadaclysm_blacksmith_sketch_reference`); false for an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_is_reference(const struct CadaclysmBlacksmithSketch *s,
                                              uint32_t id);

/**
 * Removes the entity `id` and the constraints on it; the removed constraint ids
 * come back borrowed, `count` set (a non-null pointer with count 0 when it held
 * none). Null means refused: a point that lines or circles still use is in use, and
 * `cadaclysm_blacksmith_sketch_report_ids` names the entities holding it.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty). Null when refused.
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_remove_entity(struct CadaclysmBlacksmithSketch *s,
                                                          uint32_t id,
                                                          size_t *count);

/**
 * A fixed construction copy of `other`'s entity `entity`, kept in step with
 * `cadaclysm_blacksmith_sketch_update_reference`: its id, or
 * `CADACLYSM_BLACKSMITH_NONE`. `other` must not be `s`.
 *
 * # Safety
 * `s` and `other` must be live, distinct sketches.
 */
uint32_t cadaclysm_blacksmith_sketch_reference(struct CadaclysmBlacksmithSketch *s,
                                               const struct CadaclysmBlacksmithSketch *other,
                                               uint32_t entity);

/**
 * Refreshes the reference `id` from `other` and re-solves; `report` gets
 * `{status, iterations, max_residual}`. False on failure. `other` must not be `s`.
 *
 * # Safety
 * `s` and `other` must be live, distinct sketches; `report` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_update_reference(struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id,
                                                  const struct CadaclysmBlacksmithSketch *other,
                                                  double *report);

/**
 * Adds a constraint of `kind` (a `CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_*` code, named
 * below without that prefix) on the `ref_count` entity ids in `refs`, in the order the
 * kind lists them:
 * COINCIDENT, HORIZONTAL, VERTICAL: point, point; POINT_ON_LINE, MIDPOINT: point,
 * line; POINT_ON_CIRCLE: point, circle-or-arc; PARALLEL, PERPENDICULAR, COLLINEAR,
 * EQUAL_LENGTH: line, line; TANGENT: curve, curve (`sense`); TANGENT_AT_END: free
 * curve, other (`end`); CONCENTRIC, EQUAL_RADIUS: round, round; SYMMETRIC: point,
 * point, line; FIX: entity; DISTANCE, HORIZONTAL_DISTANCE, VERTICAL_DISTANCE: point,
 * point; POINT_LINE_DISTANCE: point, line (`sense`); LINE_DISTANCE: line, line
 * (`sense`); CIRCLE_LINE_DISTANCE: round, line (`sense`); CIRCLE_DISTANCE: round,
 * round; LENGTH: line; ANGLE: line, line; RADIUS, DIAMETER: round. Dimensions read
 * `value` and `driving` (a non-driving dimension only reports); `sense` is read
 * where listed (`CADACLYSM_BLACKSMITH_SKETCH_SENSE_AUTO`, `_POSITIVE`, `_NEGATIVE`) and
 * `end` by TANGENT_AT_END (`CADACLYSM_BLACKSMITH_SKETCH_END_START` or `_END_END`); the rest are ignored. Returns the constraint id, or
 * `CADACLYSM_BLACKSMITH_NONE` (a conflicting constraint names the ones it clashes with
 * in `cadaclysm_blacksmith_sketch_report_ids`).
 *
 * # Safety
 * `s` must be a live sketch; `refs` must hold `ref_count` ids.
 */
uint32_t cadaclysm_blacksmith_sketch_constrain(struct CadaclysmBlacksmithSketch *s,
                                               uint32_t kind,
                                               const uint32_t *refs,
                                               size_t ref_count,
                                               double value,
                                               bool driving,
                                               uint32_t sense,
                                               uint32_t end);

/**
 * The live constraint ids, ascending; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_constraints(struct CadaclysmBlacksmithSketch *s,
                                                        size_t *count);

/**
 * The kind of constraint `id` (a `CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_*` code), or
 * `CADACLYSM_BLACKSMITH_NONE` for an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_constraint_kind(const struct CadaclysmBlacksmithSketch *s,
                                                     uint32_t id);

/**
 * The entity ids constraint `id` was made on, as passed to `constrain`; borrowed,
 * `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_constraint_refs(struct CadaclysmBlacksmithSketch *s,
                                                            uint32_t id,
                                                            size_t *count);

/**
 * The value of the dimension `id`. NaN for a constraint that is not a dimension
 * (no error is set) and for an unknown id (with the reason in the last error).
 *
 * # Safety
 * `s` must be a live sketch.
 */
double cadaclysm_blacksmith_sketch_constraint_value(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

/**
 * Whether the dimension `id` drives the geometry; false for a constraint that is
 * not a dimension or an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_constraint_driving(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

/**
 * The sense (`CADACLYSM_BLACKSMITH_SKETCH_SENSE_*`) of constraint `id`; `_SENSE_AUTO`
 * for a kind without one, `CADACLYSM_BLACKSMITH_NONE` for an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_constraint_sense(const struct CadaclysmBlacksmithSketch *s,
                                                      uint32_t id);

/**
 * The end of the free curve a TANGENT_AT_END constraint `id` holds:
 * `CADACLYSM_BLACKSMITH_SKETCH_END_START` or `_END_END`, as passed to `constrain`.
 * `_END_START` for every other kind (it has no end), `CADACLYSM_BLACKSMITH_NONE` for
 * an unknown id.
 *
 * # Safety
 * `s` must be a live sketch.
 */
uint32_t cadaclysm_blacksmith_sketch_constraint_end(const struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t id);

/**
 * Whether the tangent constraint `id` joins two curves end to end; false otherwise.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_is_joint_tangent(const struct CadaclysmBlacksmithSketch *s,
                                                  uint32_t id);

/**
 * Removes the constraint `id`. False on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
bool cadaclysm_blacksmith_sketch_remove(struct CadaclysmBlacksmithSketch *s, uint32_t id);

/**
 * Sets the dimension `id` to `value` and re-solves; `report` gets
 * `{status, iterations, max_residual}`. False on failure (not a dimension, ...).
 *
 * # Safety
 * `s` must be a live sketch; `report` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_set_value(struct CadaclysmBlacksmithSketch *s,
                                           uint32_t id,
                                           double value,
                                           double *report);

/**
 * Makes the dimension `id` drive the geometry (true) or only report it (false) and
 * re-solves; `report` gets `{status, iterations, max_residual}`. False on failure.
 *
 * # Safety
 * `s` must be a live sketch; `report` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_set_driving(struct CadaclysmBlacksmithSketch *s,
                                             uint32_t id,
                                             bool driving,
                                             double *report);

/**
 * What the geometry measures for the dimension `id` right now (the length of a
 * LENGTH, ...); NaN on failure.
 *
 * # Safety
 * `s` must be a live sketch.
 */
double cadaclysm_blacksmith_sketch_measure(const struct CadaclysmBlacksmithSketch *s, uint32_t id);

/**
 * Solves; `report` gets `{status, iterations, max_residual}` with the status one
 * of `CADACLYSM_BLACKSMITH_SKETCH_STATUS_CONVERGED`, `_STATUS_CONFLICTING` or
 * `_STATUS_DIVERGED`. False only for a null sketch or `report`.
 *
 * # Safety
 * `s` must be a live sketch; `report` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_solve(struct CadaclysmBlacksmithSketch *s, double *report);

/**
 * Drags the `count` points in `points` towards the targets in `xy` (x, y pairs)
 * while the constraints hold, as a live gesture would; `report` gets
 * `{status, iterations, max_residual}`. False: refused (an id that is not a point,
 * ...); otherwise read the report.
 *
 * # Safety
 * `s` must be a live sketch; `points` must hold `count` ids, `xy` `2 * count` doubles;
 * `report` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_drag(struct CadaclysmBlacksmithSketch *s,
                                      const uint32_t *points,
                                      const double *xy,
                                      size_t count,
                                      double *report);

/**
 * The ids the last call that can fail with ids or returns a report named:
 * `constrain`, `remove_entity`, `set_value`, `set_driving`, `update_reference`,
 * `solve` and `drag` each set it -- the constraints a refusal clashes with or a
 * report names, or the entities holding a point for an in-use refusal; empty when
 * that call named none. Every other call leaves it as it was (the readers, the list
 * readers `entities`, `constraints`, `ends`, `constraint_refs`, `dof_list` and
 * `dof_part_list`, `diagnose`, the `add_*` calls, the plain setters), so a refusal's
 * ids survive refreshing the lists -- also when one of those calls is refused before
 * it runs (a null `report` or array, `other` null or `s` itself): it is empty then.
 * Borrowed, `count` set.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_report_ids(const struct CadaclysmBlacksmithSketch *s,
                                                       size_t *count);

/**
 * Diagnoses the sketch's degrees of freedom: `out` gets `{free, state, part_count}`
 * with the state one of `CADACLYSM_BLACKSMITH_SKETCH_STATE_UNDER`, `_STATE_FULL` or `_STATE_OVER`.
 * The diagnosis is kept for the `dof_*` calls until the next call that changes the
 * sketch.
 *
 * # Safety
 * `s` must be a live sketch; `out` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_diagnose(struct CadaclysmBlacksmithSketch *s, double *out);

/**
 * A list from the last diagnosis: `which` is `CADACLYSM_BLACKSMITH_SKETCH_DOF_REDUNDANT`,
 * `_DOF_CONFLICTING` (constraint ids) or `_DOF_FREE_ENTITIES` (entity ids); borrowed,
 * `count` set. Null if the sketch was not diagnosed ("call sketch_diagnose first")
 * or `which` is unknown.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_dof_list(struct CadaclysmBlacksmithSketch *s,
                                                     uint32_t which,
                                                     size_t *count);

/**
 * One independent part of the diagnosed sketch (0 to `part_count - 1`): `out` gets
 * `{params, free, state}`. False if not diagnosed or out of range.
 *
 * # Safety
 * `s` must be a live sketch; `out` room for 3 doubles.
 */
bool cadaclysm_blacksmith_sketch_dof_part(const struct CadaclysmBlacksmithSketch *s,
                                          uint32_t part,
                                          double *out);

/**
 * A list of one part of the diagnosed sketch: `which` is
 * `CADACLYSM_BLACKSMITH_SKETCH_PART_CONSTRAINTS`, `_PART_REDUNDANT`,
 * `_PART_CONFLICTING` (constraint ids) or `_PART_FREE_ENTITIES` (entity ids);
 * borrowed, `count` set. Null if not diagnosed, out of range or `which` is unknown.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_dof_part_list(struct CadaclysmBlacksmithSketch *s,
                                                          uint32_t part,
                                                          uint32_t which,
                                                          size_t *count);

/**
 * The sketch's closed loops as profiles (nested loops become holes); `tolerance`
 * joins ends. Construction geometry is left out. Free with
 * `cadaclysm_blacksmith_profile_list_free`. Null on failure.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `s` must be a live sketch.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_profiles(const struct CadaclysmBlacksmithSketch *s,
                                                                            double tolerance);

/**
 * The sketch's open chains (paths that do not close) as profiles; `tolerance` joins
 * ends. Free with `cadaclysm_blacksmith_profile_list_free`. Null on failure.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `s` must be a live sketch.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_open_chains(const struct CadaclysmBlacksmithSketch *s,
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
 * A right pyramid of `sides` sides (at least 3): its base the regular polygon of
 * circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pyramid(uint32_t sides, double r, double h);

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
 * twelve doubles into `out`: for parallel planes the one halfway
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
 * about counter-clockwise. `false` and
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
 * `profile` turned `radians` (counter-clockwise) about (`cx`, `cy`), its colour kept.
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rotate(const struct CadaclysmBlacksmithProfile *profile,
                                                                       double cx,
                                                                       double cy,
                                                                       double radians);

/**
 * `profile` scaled by `sx`, `sy` about (`cx`, `cy`): an arc stays an arc where `|sx| = |sy|`,
 * and becomes exact conics otherwise. A negative factor mirrors; a zero one is refused as
 * singular (NULL and `last_error`).
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_scale(const struct CadaclysmBlacksmithProfile *profile,
                                                                      double cx,
                                                                      double cy,
                                                                      double sx,
                                                                      double sy);

/**
 * `profile` reflected across the line through (`px`, `py`) along (`dx`, `dy`). A zero or
 * non-finite direction is refused (NULL and `last_error`).
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_mirror(const struct CadaclysmBlacksmithProfile *profile,
                                                                       double px,
                                                                       double py,
                                                                       double dx,
                                                                       double dy);

/**
 * `profile` under the 2D affine map `m` (6 doubles, row-major 2×3:
 * `x' = m0 x + m1 y + m2`, `y' = m3 x + m4 y + m5`). NULL for a singular map.
 *
 * # Safety
 * `profile` a live profile; `m` 6 readable doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_transform2d(const struct CadaclysmBlacksmithProfile *profile,
                                                                            const double *m);

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
 * `solid` scaled by `factor` about the origin: every length times `factor`,
 * exactly, colours kept: a conic trim on a cylinder or cone is rewritten as the exact NURBS
 * of its stretch. NULL and `last_error` for a factor that is not positive and finite, or a
 * curve its file could not be read into.
 *
 * # Safety
 * `solid` a live solid or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_scaled(const struct CadaclysmBlacksmithSolid *solid,
                                                             double factor);

/**
 * `solid` through the affine map `matrix` (16 doubles, row-major, bottom row `0 0 0 1`),
 * exact, colours and name kept; the trims the map lost written to `inexact_out` when it is
 * not NULL. A rigid map or a similarity keeps every surface's kind -- and a map within 1e-6
 * of a similarity (`AᵀA` against `k²I`, relative to `k²`; a float32 rotation among them) is
 * applied as the exact similarity nearest it, moving a point `p` by at most about
 * `1e-6 |A| |p|`. Any other map turns the curved surfaces into their exact NURBS and maps
 * those. `inexact_out` counts the trims **lost by this call**: a face boundary that survives
 * only as a polyline lifted through the old surface, where no exact curve was left (the one
 * definition is `Reparametrised::inexact_trims` in `cadaclysm-brep`). It is per call, not
 * the solid's history, and 0 for a rigid map or a similarity. NULL and `last_error` for a
 * matrix not affine or not finite, a singular map (it flattens the solid), or a curve its
 * file could not be read into.
 *
 * # Safety
 * `solid` a live solid or NULL; `matrix` 16 readable doubles; `inexact_out` one writable `uint32_t`
 * or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_transform(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const double *matrix,
                                                                      uint32_t *inexact_out);

/**
 * `solid` with the surfaces `level` selects (`CADACLYSM_BLACKSMITH_NURBS_*`) rewritten as
 * their exact NURBS, colours and name kept; the trims lost to `inexact_out` when it is not
 * NULL, counted as [`cadaclysm_blacksmith_solid_transform`] counts them. NULL and
 * `last_error` for a level not one of the three, a surface or edge curve with no exact
 * NURBS form (`a surface has no exact NURBS form`), or a curve its file could not be read
 * into.
 *
 * # Safety
 * `solid` a live solid or NULL; `inexact_out` one writable `uint32_t` or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_convert_to_nurbs(const struct CadaclysmBlacksmithSolid *solid,
                                                                             uint32_t level,
                                                                             uint32_t *inexact_out);

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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * [`cadaclysm_blacksmith_edge`] walks) rounded to `radius`. A spline edge -- the
 * crease between two faces on NURBS surfaces, from one free edge of the shell to
 * another -- is rounded by a ball rolled along it, in a call of its own (not with
 * straight or circular edges); `tolerance` is then the fillet surface's fit,
 * floored at a millionth of the body.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * [`cadaclysm_blacksmith_fillet`] with the radius running linearly from
 * `radius_start` to `radius_end` in arc length along each edge, `radius_start` at
 * the end where the edge's curve starts. Spline edges only -- the crease between
 * two faces on NURBS surfaces, running from one free edge of the shell to another
 * (a straight or circular edge is refused). `tolerance` is the fillet surface's fit,
 * floored at a millionth of the body, as it is for a spline edge given to
 * [`cadaclysm_blacksmith_fillet`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_varying(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const uint32_t *edges,
                                                                     size_t count,
                                                                     double radius_start,
                                                                     double radius_end,
                                                                     double tolerance);

/**
 * [`cadaclysm_blacksmith_fillet`] with a radius for each picked edge, `radii[i]` for
 * `edges[i]`: spline edges only, as for [`cadaclysm_blacksmith_fillet_varying`]. The creases
 * meeting at a corner of the shell (three or more, every one picked) are rounded in one call,
 * each at its own size, and the corner between their fillets is filled by an N-sided patch
 * meeting them tangent.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edges` and `radii` `count` entries each.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_each(const struct CadaclysmBlacksmithSolid *solid,
                                                                  const uint32_t *edges,
                                                                  const double *radii,
                                                                  size_t count,
                                                                  double tolerance);

/**
 * [`cadaclysm_blacksmith_fillet`] with a flat bevel instead of a ball: every
 * picked edge cut back by `distance` along both its faces, the cut a plane (a
 * cone round a circular edge). The same edges, the same refusals.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * edges they replaced and those rounded again, as a press-pull on a fillet
 * face. Null and `last_error` for a face that is not a round of straight edges
 * between planes or of circular rims, or a radius that does not fit.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * sharp again -- the delete of a fillet face. The same refusals as
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
 * a press-pull on a chamfer face. Null and `last_error` for a face that is not
 * a chamfer's bevel, or a distance that does not fit.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * in, negative) -- a press-pull on a selection: each face by
 * [`cadaclysm_blacksmith_push_pull`]'s rule for it, one after another in the order
 * given, each found again by a point inside it after the pushes before it renumbered the
 * faces. A box's top and a side pushed 5 is the box 5 taller and 5 wider. A face on the
 * same curved surface as one before it, and joined to it, moved with that one and is
 * not pushed twice. Null and `last_error` for no faces, a face an earlier push took
 * away, and whatever [`cadaclysm_blacksmith_push_pull`] refuses of a face.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `solid` split by `tool` into bodies. A closed `tool`
 * gives the part outside it, then the part inside; a flat sheet splits by the
 * whole plane it lies on. Every connected part is a body, and the bodies come
 * back side by side in one solid: take them apart with
 * [`cadaclysm_blacksmith_lump_count`] and [`cadaclysm_blacksmith_lump`]. Null and
 * `last_error` for a tool that does not cross the solid, or a curved sheet.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `solid` split by the closed `profile` drawn on `frame` (twelve doubles: origin,
 * x, y, z), pushed straight through it along z both ways -- a split by
 * a sketch profile: the bodies outside the profile, then inside, side by side in
 * one solid ([`cadaclysm_blacksmith_lump`] takes them apart). Where the plane lies
 * along z does not matter. Null and `last_error` where the profile misses the solid
 * or takes all of it, or encloses nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` and `profile` live; `frame` twelve doubles; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_profile(const struct CadaclysmBlacksmithSolid *solid,
                                                                       const struct CadaclysmBlacksmithProfile *profile,
                                                                       const double *frame,
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
 * its own, its faces in `solid`'s order and colours. Not a verb: each face and edge
 * keeps its id and its origins as `solid` has them, so the bodies of a split name the
 * split's operands. Null and `last_error` for an index the solid has no body at.
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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * `solid`, a sheet, made a solid `thickness` thick: its faces,
 * their twins moved `thickness` along the faces' normals (against them for a negative
 * thickness), and a wall round every open edge. Two faces of a folded sheet meet on
 * their offsets' mitre; a closed sheet thickens to a hollow. Free-form (NURBS) faces
 * offset by a fit held to `tolerance`. Null and `last_error` for a thickness a face
 * cannot take (a radius used up, a free-form offset folding over).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * A box of `sx` x `sy` x `sz`, centred on the origin, with `nx`, `ny`, `nz`
 * quads along each axis. Null (and `last_error`) for a size not finite and
 * positive, or a count of 0 or over 1024.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cuboid(double sx,
                                                                 double sy,
                                                                 double sz,
                                                                 uint32_t nx,
                                                                 uint32_t ny,
                                                                 uint32_t nz);

/**
 * A cylinder along +Z of `radius` and `height`: one n-gon cap per end with
 * `sides` sides and `rings` bands of quads between them; with `creased_rims`
 * the two rim loops are creased, so the caps stay flat. Null (and
 * `last_error`) for a size not finite and positive, or a count out of range.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cylinder(double radius,
                                                                   double height,
                                                                   uint32_t sides,
                                                                   uint32_t rings,
                                                                   bool creased_rims);

/**
 * A quad ball of `radius`: a cube grid with `segments` quads per edge, each
 * vertex pushed out to the radius. Null (and `last_error`) for a radius not
 * finite and positive, or `segments` out of range.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_sphere(double radius, uint32_t segments);

/**
 * A torus around +Z: `around` steps about the axis at `major`, `tube` steps
 * round the tube of `minor`, all quads. Null (and `last_error`) for sizes not
 * finite and positive, or counts out of range.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_torus(double major,
                                                                double minor,
                                                                uint32_t around,
                                                                uint32_t tube);

/**
 * A cage from its parts, the lossless inverse of
 * [`cadaclysm_blacksmith_subd_parts`] (see [`CadaclysmBlacksmithSubdParts`] for
 * each array's shape): a saved cage, a mirrored half included, loads back
 * equal. `symmetry_tolerance` is ignored when `symmetry_axis` is -1. The new
 * handle selects nothing. Null (and `last_error`, naming the parameter) for
 * `vertex_count` 0, a null array with a positive count, `face_sizes` that do
 * not sum to `index_count`, or `symmetry_axis` not -1, 0, 1 or 2; null with the
 * kernel's own words for a cage it refuses (an index out of range, a face of
 * fewer than three vertices, a non-manifold edge, a crease that is not an
 * edge, a half that does not weld to its reflection).
 *
 * # Safety
 * Each array readable for the count its parameter documents, or null with a
 * zero count.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_from_parts(const double *positions,
                                                                     uint32_t vertex_count,
                                                                     const uint32_t *face_sizes,
                                                                     uint32_t face_count,
                                                                     const uint32_t *face_indices,
                                                                     uint32_t index_count,
                                                                     const uint32_t *creases,
                                                                     uint32_t crease_count,
                                                                     const uint32_t *pins,
                                                                     uint32_t pin_count,
                                                                     int32_t symmetry_axis,
                                                                     double symmetry_tolerance);

/**
 * `subd`'s parts into `out`, as views valid until `subd` is freed. `false` (and
 * `last_error`) for a null `subd` or `out`.
 *
 * # Safety
 * `subd` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_subd_parts(const struct CadaclysmBlacksmithSubd *subd,
                                     struct CadaclysmBlacksmithSubdParts *out);

/**
 * Release a cage. Null is a no-op. Views from
 * [`cadaclysm_blacksmith_subd_parts`] and
 * [`cadaclysm_blacksmith_subd_smooth_mesh`] die with it.
 *
 * # Safety
 * `subd` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_subd_free(struct CadaclysmBlacksmithSubd *subd);

/**
 * A new cage with the selected elements moved by `matrix` (16 doubles,
 * column-major; a rotation about a point is baked in by the caller). `kind` is
 * 0 vertices, 1 edges, 2 faces; `ids` is `id_count` elements, an edge
 * selection `2 * id_count` vertex ids. The new handle selects the same
 * elements. Null (and `last_error`) for a null `subd` or `matrix`, a null `ids`
 * with a positive count, a `kind` out of range, or the kernel's refusal (an id
 * not in the cage, a matrix not finite or mirroring).
 *
 * # Safety
 * `subd` live; `ids` readable as described; `matrix` 16 doubles.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_transform(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t kind,
                                                                    const uint32_t *ids,
                                                                    uint32_t id_count,
                                                                    const double *matrix);

/**
 * A new cage with the `edge_count` edges at `edges` (`2 * edge_count` vertex
 * ids) creased, or un-creased when `on` is false; the new handle selects them.
 * Null (and `last_error`) for a null `subd`, a null `edges` with a positive
 * count, or the kernel's refusal (an empty selection, a pair that is not an
 * edge).
 *
 * # Safety
 * `subd` live; `edges` readable as described.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_crease(const struct CadaclysmBlacksmithSubd *subd,
                                                                     const uint32_t *edges,
                                                                     uint32_t edge_count,
                                                                     bool on);

/**
 * A new cage with the `vertex_count` vertices at `vertices` pinned (they
 * refine as corners and stay put), or released when `on` is false; the new
 * handle selects them. Null (and `last_error`) for a null `subd`, a null
 * `vertices` with a positive count, or the kernel's refusal (an empty
 * selection, a vertex not in the cage).
 *
 * # Safety
 * `subd` live; `vertices` readable for `vertex_count` entries.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_pin(const struct CadaclysmBlacksmithSubd *subd,
                                                                  const uint32_t *vertices,
                                                                  uint32_t vertex_count,
                                                                  bool on);

/**
 * A new cage with the `face_count` faces at `faces` pushed out by `distance`
 * along each connected region's average normal, a quad wall on each boundary
 * edge; the moved faces keep their ids and the new handle selects them. Null
 * (and `last_error`) for a null `subd`, a null `faces` with a positive count,
 * or the kernel's refusal.
 *
 * # Safety
 * `subd` live; `faces` readable for `face_count` entries.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_extrude(const struct CadaclysmBlacksmithSubd *subd,
                                                                  const uint32_t *faces,
                                                                  uint32_t face_count,
                                                                  double distance);

/**
 * A new cage with the `face_count` faces at `faces` shrunk by `amount`, in
 * `(0, 1)`, within their surface and a ring of quads round each region (each
 * face, with `individual`); the new handle selects the inner faces. Null (and
 * `last_error`) for a null `subd`, a null `faces` with a positive count, or the
 * kernel's refusal.
 *
 * # Safety
 * `subd` live; `faces` readable for `face_count` entries.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_inset(const struct CadaclysmBlacksmithSubd *subd,
                                                                const uint32_t *faces,
                                                                uint32_t face_count,
                                                                double amount,
                                                                bool individual);

/**
 * A new cage with the `face_count` faces at `faces` (the whole cage when
 * `face_count` is 0) subdivided once by the Catmull-Clark rules: each becomes
 * quads round a new point, and an unpicked face beside them takes the new edge
 * points as corners. The whole cage keeps its smooth surface exactly. The new
 * handle selects the new faces. Null (and `last_error`) for a null `subd`, a
 * null `faces` with a positive count, or the kernel's refusal.
 *
 * # Safety
 * `subd` live; `faces` readable for `face_count` entries.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_subdivide(const struct CadaclysmBlacksmithSubd *subd,
                                                                    const uint32_t *faces,
                                                                    uint32_t face_count);

/**
 * A new cage with a loop of edges cut across the ring of quads through edge
 * `(a, b)`, at `a + at * (b - a)` with `at` in `(0, 1)`; the new handle selects
 * the new loop's edges. Null (and `last_error`) for a null `subd`, or the
 * kernel's refusal (not an edge, `at` out of range, a ring that folds back on
 * itself).
 *
 * # Safety
 * `subd` live.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_insert_loop(const struct CadaclysmBlacksmithSubd *subd,
                                                                      uint32_t a,
                                                                      uint32_t b,
                                                                      double at);

/**
 * The positive half of the cage across the plane perpendicular to `axis` (0
 * X, 1 Y, 2 Z) as a mirrored cage: every later edit keeps it symmetric. Selects
 * nothing. Null (and `last_error`) for a null `subd`, an `axis` out of range,
 * or the kernel's refusal (a face crossing the plane, nothing on the positive
 * side, a half that would not weld).
 *
 * # Safety
 * `subd` live.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_on(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t axis);

/**
 * The mirror baked: the whole cage as an ordinary one, no longer mirrored
 * (`symmetry_axis` -1). Selects nothing. Null (and `last_error`) for a null
 * `subd`.
 *
 * # Safety
 * `subd` live.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_off(const struct CadaclysmBlacksmithSubd *subd);

/**
 * The whole cage of a mirrored half -- the half's vertices first, then the
 * reflections of those off the plane -- or a copy of an ordinary cage. Selects
 * nothing. Null (and `last_error`) for a null `subd`.
 *
 * # Safety
 * `subd` live.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_full(const struct CadaclysmBlacksmithSubd *subd);

/**
 * The loop of edges through edge `(a, b)`, straight across each valence-four
 * vertex, written into the returned handle's selection (kind 1, the picked edge
 * first, each smaller id first); the cage itself unchanged. An empty selection
 * when `(a, b)` is not an edge. Null (and `last_error`) for a null `subd`.
 *
 * # Safety
 * `subd` live.
 */
struct CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_edge_loop(const struct CadaclysmBlacksmithSubd *subd,
                                                                    uint32_t a,
                                                                    uint32_t b);

/**
 * The smooth surface refined `levels` times (1 to 6) into `out`: see
 * [`CadaclysmBlacksmithSubdMesh`]. Cached on the handle per level -- the same
 * levels again hands back the same arrays, and every view stays valid until
 * [`cadaclysm_blacksmith_subd_free`], whatever levels are asked for after it. `false` (and `last_error`) for a null `subd` or
 * `out`, or `levels` out of range.
 *
 * # Safety
 * `subd` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_subd_smooth_mesh(const struct CadaclysmBlacksmithSubd *subd,
                                           uint32_t levels,
                                           struct CadaclysmBlacksmithSubdMesh *out);

/**
 * The cage element of `kind` (0 vertex, 1 edge, 2 face) under `point` (3
 * doubles), a point on or near the smooth surface: its id into `out[0]`, and
 * for an edge its second vertex into `out[1]` (smaller id first; 0 otherwise,
 * so both are always written). On a mirrored
 * half, the half's own ids whichever side the point is on. `false` with an
 * **empty** `last_error` when nothing is within `0.05` of the full cage's
 * diagonal; `false` with `last_error` saying why for a null `subd`, `point` or
 * `out`, a `kind` out of range, or a point that is not finite.
 *
 * # Safety
 * `subd` live; `point` 3 doubles; `out` room for 2.
 */
bool cadaclysm_blacksmith_subd_pick(const struct CadaclysmBlacksmithSubd *subd,
                                    const double *point,
                                    uint32_t kind,
                                    uint32_t *out);

/**
 * The cage as an exact solid, one NURBS face per patch of its conversion, that
 * every solid call takes; `report`, when not null, says what the conversion did
 * and how close it came. `tolerance <= 0`, `g1_angle_deg <= 0` and `max_levels`
 * 0 take the defaults (1e-4 of the diagonal, 0.1 degrees, 6 levels). Null (and
 * `last_error`) for a null `subd`, options out of range (`max_levels` from 2 to
 * 6, a NaN), or a cage the conversion cannot hold within them, refused with the
 * figures it measured (`subd: outside tolerance after ... levels: deviation
 * ..., tangent break ... deg`).
 *
 * # Safety
 * `subd` live; `report` null or a valid struct.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_subd_to_solid(const struct CadaclysmBlacksmithSubd *subd,
                                                                    double tolerance,
                                                                    double g1_angle_deg,
                                                                    uint32_t max_levels,
                                                                    struct CadaclysmBlacksmithSubdReport *report);

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
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
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
 * A circle of `radius` swept along `path`, square to its start:
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

/**
 * The `count` solids measured against each other, meshed at `tolerance`
 * (positive and finite, or unset). Null (and `last_error`) for a null `solids`, a null
 * solid in it, or a bad tolerance. `solids` must not be null, even with `count`
 * 0 (pass any non-null pointer for an empty gauge).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solids` readable for `count` entries, each null or a live solid.
 */
struct CadaclysmBlacksmithThicknessGauge *cadaclysm_blacksmith_thickness_gauge_new(const struct CadaclysmBlacksmithSolid *const *solids,
                                                                                   uint32_t count,
                                                                                   double tolerance);

/**
 * Release a thickness gauge. Null is a no-op.
 *
 * # Safety
 * `gauge` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_thickness_gauge_free(struct CadaclysmBlacksmithThicknessGauge *gauge);

/**
 * How many bodies the gauge measures. 0 (and `last_error`) for null.
 *
 * # Safety
 * `gauge` live.
 */
uint32_t cadaclysm_blacksmith_thickness_gauge_body_count(const struct CadaclysmBlacksmithThicknessGauge *gauge);

/**
 * The tolerance the gauge meshed its bodies at. NaN (and `last_error`) for
 * null.
 *
 * # Safety
 * `gauge` live.
 */
double cadaclysm_blacksmith_thickness_gauge_tolerance(const struct CadaclysmBlacksmithThicknessGauge *gauge);

/**
 * Body `body`'s measuring mesh into `out`, borrowed from the gauge. `false`
 * (and `last_error`) for a null `gauge` or `out`, or a body past the end;
 * `out` is untouched then.
 *
 * # Safety
 * `gauge` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_thickness_gauge_mesh(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                               uint32_t body,
                                               struct CadaclysmBlacksmithThicknessMesh *out);

/**
 * One reading per measuring-mesh vertex that has one within `maximum`
 * (positive and finite), by body then vertex; vertices whose interior angle is
 * under `sharp_angle` radians (zero or more, finite) are knife edges. Null (and
 * `last_error`) for a null `gauge` or a bad limit.
 *
 * # Safety
 * `gauge` live.
 */
struct CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_measure(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                                                                    double maximum,
                                                                                    double sharp_angle);

/**
 * The reading at `point`'s foot on face `face` of body `body` (three doubles):
 * a list of one row, its `vertex` `CADACLYSM_BLACKSMITH_NONE`, or of none where
 * the foot lies off the face or the wall is thicker than `maximum`. Null (and
 * `last_error`) for a null `gauge` or `point`, a body or face past the end, a
 * point that is not finite, or a bad limit.
 *
 * # Safety
 * `gauge` live; `point` null or three readable doubles.
 */
struct CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_at(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                                                               uint32_t body,
                                                                               uint32_t face,
                                                                               const double *point,
                                                                               double maximum,
                                                                               double sharp_angle);

/**
 * One thickness for face `face` of body `body` into `out`:
 * measured at `at`'s foot on the face (`at` three doubles) or, with `at` null,
 * over the face's vertices; the other bodies are measured with it. `found`
 * false where nothing reads under `maximum`. `false` (and `last_error`) for a
 * null `gauge` or `out`, a body or face past the end, an `at` that is not
 * finite, or a bad maximum; `out` is untouched then.
 *
 * # Safety
 * `gauge` live; `at` null or three readable doubles; `out` a valid struct.
 */
bool cadaclysm_blacksmith_thickness_gauge_face(const struct CadaclysmBlacksmithThicknessGauge *gauge,
                                               uint32_t body,
                                               uint32_t face,
                                               const double *at,
                                               double maximum,
                                               struct CadaclysmBlacksmithFaceThickness *out);

/**
 * Release a thicknesses list. Null is a no-op.
 *
 * # Safety
 * `list` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_thicknesses_free(struct CadaclysmBlacksmithThicknesses *list);

/**
 * How many readings. 0 (and `last_error`) for null.
 *
 * # Safety
 * `list` live.
 */
uint32_t cadaclysm_blacksmith_thicknesses_count(const struct CadaclysmBlacksmithThicknesses *list);

/**
 * Reading `i` into `out`. `false` (and `last_error`) for a null `list` or
 * `out`, or `i` out of range; `out` is untouched then.
 *
 * # Safety
 * `list` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_thicknesses_at(const struct CadaclysmBlacksmithThicknesses *list,
                                         uint32_t i,
                                         struct CadaclysmBlacksmithThickness *out);

/**
 * The nearest-opposing-wall rule on `mesh_count` meshes laid end to end,
 * measured against each other: mesh m's vertices are the next
 * `vertex_counts[m]` triples of `positions`, its triangles the next
 * `triangle_counts[m]` triples of `indices`, indexing its own vertices. One
 * reading per vertex that has one within `maximum` (positive and finite), by
 * mesh then vertex; `sharp_angle` (radians, zero or more) as
 * `_thickness_gauge_measure`. Null (and `last_error`) for a null array with a
 * count, a triangle past its mesh, a position that is not finite, or a bad
 * limit.
 *
 * # Safety
 * `vertex_counts` and `triangle_counts` readable for `mesh_count` entries;
 * `positions` for three doubles per vertex they count, `indices` for three
 * entries per triangle (either may be null when its counts sum to zero).
 */
struct CadaclysmBlacksmithMeshThicknesses *cadaclysm_blacksmith_mesh_thickness(const double *positions,
                                                                               const uint32_t *vertex_counts,
                                                                               const uint32_t *indices,
                                                                               const uint32_t *triangle_counts,
                                                                               uint32_t mesh_count,
                                                                               double maximum,
                                                                               double sharp_angle);

/**
 * Release a mesh thicknesses list. Null is a no-op.
 *
 * # Safety
 * `list` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_mesh_thicknesses_free(struct CadaclysmBlacksmithMeshThicknesses *list);

/**
 * How many readings. 0 (and `last_error`) for null.
 *
 * # Safety
 * `list` live.
 */
uint32_t cadaclysm_blacksmith_mesh_thicknesses_count(const struct CadaclysmBlacksmithMeshThicknesses *list);

/**
 * Reading `i` into `out`. `false` (and `last_error`) for a null `list` or
 * `out`, or `i` out of range; `out` is untouched then.
 *
 * # Safety
 * `list` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_mesh_thicknesses_at(const struct CadaclysmBlacksmithMeshThicknesses *list,
                                              uint32_t i,
                                              struct CadaclysmBlacksmithMeshThickness *out);

/**
 * The translation by `v`.
 *
 * # Safety
 * `v` 3 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_translation(const double *v, double *out);

/**
 * A turn of `radians` about `axis` (a point and a direction), right-handed.
 *
 * # Safety
 * `axis` 6 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_rotation(const double *axis, double radians, double *out);

/**
 * The reflection across `plane` (a frame; its z the normal). A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `plane` 12 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_mirror(const double *plane,
                                           double *out);

/**
 * A uniform scale by `k` about `centre`.
 *
 * # Safety
 * `centre` 3 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_scale(const double *centre, double k, double *out);

/**
 * A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin. A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `frame` 12 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_scale_xyz(const double *frame,
                                              double sx,
                                              double sy,
                                              double sz,
                                              double *out);

/**
 * The shear `p + factor ((p - o) . n) d` over `plane` (its z the normal): `dir` is
 * normalised -- `factor` alone sets the slide -- and must lie in the plane. A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `plane` 12 readable doubles, `dir` 3; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_shear(const double *plane,
                                          const double *dir,
                                          double factor,
                                          double *out);

/**
 * The rigid map sending frame `a` onto frame `b`. A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `a`, `b` 12 readable doubles each; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_plane_to_plane(const double *a,
                                                   const double *b,
                                                   double *out);

/**
 * Coordinates in frame `from` to coordinates in frame `to`: a change of basis. A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `from`, `to` 12 readable doubles each; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_change_basis(const double *from,
                                                 const double *to,
                                                 double *out);

/**
 * The orthogonal projection onto `plane` (singular by design). A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `plane` 12 readable doubles; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_planar_projection(const double *plane,
                                                      double *out);

/**
 * The parallel projection onto `plane` along `dir`; `false` for a `dir` in the plane.
 * A frame within 1e-6 of right-handed and orthonormal is squared up; anything further is refused.
 *
 * # Safety
 * `plane` 12 readable doubles, `dir` 3; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_transform_project_along(const double *plane,
                                                  const double *dir,
                                                  double *out);

/**
 * `a` after `b`.
 *
 * # Safety
 * `a`, `b` 16 readable doubles each; `out` 16 writable doubles (it may be `a` or `b`).
 */
bool cadaclysm_blacksmith_transform_compose(const double *a, const double *b, double *out);

/**
 * The inverse; `false` for a singular map.
 *
 * # Safety
 * `m` 16 readable doubles; `out` 16 writable doubles (it may be `m`).
 */
bool cadaclysm_blacksmith_transform_inverse(const double *m, double *out);

/**
 * 1 where `m`'s linear part is orthogonal to `tolerance` (`AᵀA = I`), 0 where it is not,
 * `CADACLYSM_BLACKSMITH_NONE` and `last_error` for a matrix or tolerance refused.
 *
 * # Safety
 * `m` 16 readable doubles.
 */
uint32_t cadaclysm_blacksmith_transform_is_rigid(const double *m, double tolerance);

/**
 * `k > 0` where `m`'s linear part is `k` times an orthogonal one (`AᵀA = k²I` to `tolerance`
 * relative to `k²`), 0 where it is not, NaN and `last_error` for a matrix or tolerance refused.
 *
 * # Safety
 * `m` 16 readable doubles.
 */
double cadaclysm_blacksmith_transform_is_similarity(const double *m, double tolerance);

/**
 * A rigid map split: the translation (3), then the orthogonal linear part (16).
 * `false` where the map is not rigid to `tolerance`.
 *
 * # Safety
 * `m` 16 readable doubles; `out` 19 writable doubles.
 */
bool cadaclysm_blacksmith_transform_decompose_rigid(const double *m, double tolerance, double *out);

/**
 * A similarity split: the translation (3), the orthogonal part (16), then `k`.
 * `false` where the map is not a similarity to `tolerance`.
 *
 * # Safety
 * `m` 16 readable doubles; `out` 20 writable doubles.
 */
bool cadaclysm_blacksmith_transform_decompose_similarity(const double *m,
                                                         double tolerance,
                                                         double *out);

/**
 * The polar split of the map: the translation (3), `rotation` (16, carrying the mirror where
 * `det < 0`), `axes` (16, a proper rotation whose columns are the stretch directions), then
 * the three stretches, largest first -- the linear part is
 * `rotation · axes · diag(stretch) · axesᵀ`. `false` for a singular map, or one stretched
 * past 1e7:1.
 *
 * # Safety
 * `m` 16 readable doubles; `out` 38 writable doubles.
 */
bool cadaclysm_blacksmith_transform_decompose_affine(const double *m, double *out);

/**
 * The turn of `radians` about `dir`, `w x y z`.
 *
 * # Safety
 * `dir` 3 readable doubles; `out` 4 writable doubles.
 */
bool cadaclysm_blacksmith_quaternion_from_axis_angle(const double *dir,
                                                     double radians,
                                                     double *out);

/**
 * The rotation in `m`'s linear part; `false` unless it is a proper rotation (orthogonal to
 * 1e-9, determinant positive). That is stricter than `cadaclysm_blacksmith_solid_transform`,
 * which snaps a map within 1e-6 of a similarity: a rotation rounded to float32 is refused
 * here. Take the `rotation` of `cadaclysm_blacksmith_transform_decompose_affine` first --
 * it is orthogonal to rounding -- and ask its quaternion.
 *
 * # Safety
 * `m` 16 readable doubles; `out` 4 writable doubles.
 */
bool cadaclysm_blacksmith_quaternion_from_transform(const double *m, double *out);

/**
 * `q`'s rotation fixing `centre`. A non-unit quaternion is normalised; a zero or non-finite one is refused.
 *
 * # Safety
 * `q` 4 readable doubles, `centre` 3; `out` 16 writable doubles.
 */
bool cadaclysm_blacksmith_quaternion_to_transform(const double *q,
                                                  const double *centre,
                                                  double *out);

/**
 * From `a` (`s = 0`) to `b` (`s = 1`) the shorter way. A non-unit quaternion is normalised; a zero or non-finite one is refused.
 *
 * # Safety
 * `a`, `b` 4 readable doubles each; `out` 4 writable doubles.
 */
bool cadaclysm_blacksmith_quaternion_slerp(const double *a,
                                           const double *b,
                                           double s,
                                           double *out);

/**
 * How many doubles a value of `kind` is; 0 for an unknown kind. The arrays, `frame[12]`
 * being `origin x y z` as every frame in the ABI:
 *
 * | kind | array | count |
 * |---|---|---|
 * | 0 `CADACLYSM_BLACKSMITH_VALUE_LINE` | `from[3] to[3]` | 6 |
 * | 1 `CADACLYSM_BLACKSMITH_VALUE_CIRCLE` | `frame[12] radius` | 13 |
 * | 2 `CADACLYSM_BLACKSMITH_VALUE_ARC` | `frame[12] radius t0 t1` | 15 |
 * | 3 `CADACLYSM_BLACKSMITH_VALUE_ELLIPSE` | `frame[12] r1 r2` | 14 |
 * | 4 `CADACLYSM_BLACKSMITH_VALUE_SPHERE` | `frame[12] radius` | 13 |
 * | 5 `CADACLYSM_BLACKSMITH_VALUE_CYLINDER` | `frame[12] radius h0 h1` | 15 |
 * | 6 `CADACLYSM_BLACKSMITH_VALUE_CONE` | `frame[12] radius height` | 14 |
 * | 7 `CADACLYSM_BLACKSMITH_VALUE_TORUS` | `frame[12] major minor` | 14 |
 * | 8 `CADACLYSM_BLACKSMITH_VALUE_CUBOID` | `frame[12] x0 x1 y0 y1 z0 z1` | 18 |
 * | 9 `CADACLYSM_BLACKSMITH_VALUE_RECTANGLE` | `frame[12] x0 x1 y0 y1` | 16 |
 * | 10 `CADACLYSM_BLACKSMITH_VALUE_TRIANGLE` | `a[3] b[3] c[3]` | 9 |
 * | 11 `CADACLYSM_BLACKSMITH_VALUE_RAY` | `position[3] direction[3]` | 6 |
 *
 * Curves are kinds 0-3 and 9 (the rectangle's boundary), surfaces 4-7, shapes with a volume
 * 4-8; the rectangle, triangle and ray have calls of their own (`rectangle_*`, `triangle_*`,
 * `ray_*`). A call given a kind outside its family is refused. A frame within 1e-6 of right-handed and orthonormal is squared up,
 * anything further refused; every call checks the whole array (finite, sizes positive,
 * ranges increasing), so `cadaclysm_blacksmith_value_check` is never a precondition.
 */
uint32_t cadaclysm_blacksmith_value_size(uint32_t kind);

/**
 * `value` validated and canonical (its frame squared up), per
 * `cadaclysm_blacksmith_value_size`.
 *
 * # Safety
 * `value` and `out` `value_size(kind)` doubles each (they may be the same array).
 */
bool cadaclysm_blacksmith_value_check(uint32_t kind, const double *value, double *out);

/**
 * The world box: `min[3]` then `max[3]`; a ray, unbounded, is refused. Layouts per
 * `cadaclysm_blacksmith_value_size`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 6.
 */
bool cadaclysm_blacksmith_value_bounds(uint32_t kind, const double *value, double *out);

/**
 * `value` under `matrix` (16 doubles, row-major), the same kind. A line takes any map that
 * keeps its ends apart, an ellipse any that keeps it an ellipse, a triangle any that keeps it
 * a triangle, a ray any that keeps its direction (the position as a point, the direction as a
 * vector), a rectangle any that keeps its sides square (no shear in its plane); every other
 * kind only a similarity (a circle under another map: `cadaclysm_blacksmith_ellipse_from_circle`
 * first).
 *
 * # Safety
 * `value` and `out` `value_size(kind)` doubles each (they may be the same array); `matrix` 16.
 */
bool cadaclysm_blacksmith_value_transform(uint32_t kind,
                                          const double *value,
                                          const double *matrix,
                                          double *out);

/**
 * A curve's (kinds 0-3 and 9) point at `t`, per `cadaclysm_blacksmith_value_size`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 3.
 */
bool cadaclysm_blacksmith_curve_value_point_at(uint32_t kind,
                                               const double *value,
                                               double t,
                                               double *out);

/**
 * A curve's unit tangent at `t`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 3.
 */
bool cadaclysm_blacksmith_curve_value_tangent_at(uint32_t kind,
                                                 const double *value,
                                                 double t,
                                                 double *out);

/**
 * A curve's length (an ellipse's perimeter in closed form) into `out`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 1.
 */
bool cadaclysm_blacksmith_curve_value_length(uint32_t kind, const double *value, double *out);

/**
 * The curve's closest point to `point`: `t x y z unique`, `unique` 1, or 0 where the answer
 * is a fixed pick among equals (a circle's axis, an arc's two equidistant ends).
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `point` 3; `out` 5.
 */
bool cadaclysm_blacksmith_curve_value_closest_point(uint32_t kind,
                                                    const double *value,
                                                    const double *point,
                                                    double *out);

/**
 * The curve's exact NURBS form, freed with `cadaclysm_blacksmith_nurbs_curve_free`; NULL and
 * `last_error` on a refusal.
 *
 * # Safety
 * `value` `value_size(kind)` doubles.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_curve_value_to_nurbs(uint32_t kind,
                                                                                const double *value);

/**
 * The circle through three points, a kind-1 array: x toward `a`, the normal so `a`, `b`, `c`
 * run counter-clockwise.
 *
 * # Safety
 * `a`, `b`, `c` 3 doubles each; `out` 13.
 */
bool cadaclysm_blacksmith_circle_through(const double *a,
                                         const double *b,
                                         const double *c,
                                         double *out);

/**
 * The arc from `a` through `b` to `c`, a kind-2 array starting at angle 0.
 *
 * # Safety
 * `a`, `b`, `c` 3 doubles each; `out` 15.
 */
bool cadaclysm_blacksmith_arc_through(const double *a,
                                      const double *b,
                                      const double *c,
                                      double *out);

/**
 * The arc leaving `a` along `tangent` and ending at `c`, a kind-2 array.
 *
 * # Safety
 * `a`, `tangent`, `c` 3 doubles each; `out` 15.
 */
bool cadaclysm_blacksmith_arc_from_start_tangent_end(const double *a,
                                                     const double *tangent,
                                                     const double *c,
                                                     double *out);

/**
 * A circle (kind 1) as the round ellipse (kind 3): how a circle takes a map that is not a
 * similarity.
 *
 * # Safety
 * `value` 13 doubles; `out` 14.
 */
bool cadaclysm_blacksmith_ellipse_from_circle(const double *value, double *out);

/**
 * A surface's (kinds 4-7) point at `(u, v)`: `u` the angle round the axis; `v` a sphere's
 * latitude, a cylinder's or cone's height along the axis, a torus' angle round the tube.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 3.
 */
bool cadaclysm_blacksmith_surface_value_point_at(uint32_t kind,
                                                 const double *value,
                                                 double u,
                                                 double v,
                                                 double *out);

/**
 * A surface's outward unit normal at `(u, v)`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 3.
 */
bool cadaclysm_blacksmith_surface_value_normal_at(uint32_t kind,
                                                  const double *value,
                                                  double u,
                                                  double v,
                                                  double *out);

/**
 * The patch's closest point to `point`: `u v x y z unique`, `unique` 1 or 0.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `point` 3; `out` 6.
 */
bool cadaclysm_blacksmith_surface_value_closest_point(uint32_t kind,
                                                      const double *value,
                                                      const double *point,
                                                      double *out);

/**
 * The patch's parameter box: `u0 u1 v0 v1`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 4.
 */
bool cadaclysm_blacksmith_surface_value_domain(uint32_t kind, const double *value, double *out);

/**
 * The whole patch as one open face on its exact NURBS form, freed with
 * `cadaclysm_blacksmith_solid_free`; NULL and `last_error` on a refusal.
 *
 * # Safety
 * `value` `value_size(kind)` doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_surface_value_nurbs_sheet(uint32_t kind,
                                                                                const double *value);

/**
 * 1 where `point` lies inside the closed shape (kinds 4-8) or within `tolerance` of it, 0
 * where it does not, `CADACLYSM_BLACKSMITH_NONE` and `last_error` on a refusal. `tolerance`
 * NaN is unset, the shape's own effective tolerance (`tolerance.relative` times its box's
 * diagonal, never finer than its coordinates' rounding); 0 is exact (see the tolerances
 * section at `cadaclysm_blacksmith_effective_tolerance`).
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `point` 3.
 */
uint32_t cadaclysm_blacksmith_solid_value_contains(uint32_t kind,
                                                   const double *value,
                                                   const double *point,
                                                   double tolerance);

/**
 * The closed shape's boundary area (caps included) into `out`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 1.
 */
bool cadaclysm_blacksmith_solid_value_area(uint32_t kind, const double *value, double *out);

/**
 * The enclosed volume into `out`.
 *
 * # Safety
 * `value` `value_size(kind)` doubles; `out` 1.
 */
bool cadaclysm_blacksmith_solid_value_volume(uint32_t kind, const double *value, double *out);

/**
 * The closed B-rep solid the value bounds, freed with `cadaclysm_blacksmith_solid_free`;
 * NULL and `last_error` on a refusal.
 *
 * # Safety
 * `value` `value_size(kind)` doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_value_to_solid(uint32_t kind,
                                                                           const double *value);

/**
 * The world-aligned box from `min` to `max`, a kind-8 array.
 *
 * # Safety
 * `min`, `max` 3 doubles each; `out` 18.
 */
bool cadaclysm_blacksmith_cuboid_from_bounds(const double *min, const double *max, double *out);

/**
 * The tightest box holding `count` points (`xyz`, three doubles each), aligned to `frame`;
 * a kind-8 array.
 *
 * # Safety
 * `frame` 12 doubles; `xyz` `3 * count`; `out` 18.
 */
bool cadaclysm_blacksmith_cuboid_around(const double *frame,
                                        const double *xyz,
                                        size_t count,
                                        double *out);

/**
 * A box's eight corners, xyz each: the `z0` face counter-clockwise about +z from
 * `(x0, y0)`, then the `z1` face in the same order.
 *
 * # Safety
 * `value` 18 doubles; `out` 24.
 */
bool cadaclysm_blacksmith_cuboid_corners(const double *value, double *out);

/**
 * The point the fractions `sx`, `sy`, `sz` of the way along a box's ranges (outside `0..1`
 * extrapolates).
 *
 * # Safety
 * `value` 18 doubles; `out` 3.
 */
bool cadaclysm_blacksmith_cuboid_point_at(const double *value,
                                          double sx,
                                          double sy,
                                          double sz,
                                          double *out);

/**
 * The solid box's closest point to `point` (`point` itself inside).
 *
 * # Safety
 * `value` 18 doubles; `point` 3; `out` 3.
 */
bool cadaclysm_blacksmith_cuboid_closest_point(const double *value,
                                               const double *point,
                                               double *out);

/**
 * A rectangle's four corners, xyz each, in Rhino's `Corner(i)` order: `(x0,y0) (x1,y0)
 * (x1,y1) (x0,y1)`, counter-clockwise about the frame's z.
 *
 * # Safety
 * `value` 16 doubles; `out` 12.
 */
bool cadaclysm_blacksmith_rectangle_corners(const double *value, double *out);

/**
 * The filled rectangle's area into `out`.
 *
 * # Safety
 * `value` 16 doubles; `out` 1.
 */
bool cadaclysm_blacksmith_rectangle_area(const double *value, double *out);

/**
 * Rhino's `ClosestPoint(p, includeInterior)`: `point` projected onto the rectangle's plane
 * and clamped into the filled rectangle when `include_interior`, else the boundary's closest
 * point (`cadaclysm_blacksmith_curve_value_closest_point` gives its `t` and `unique` too).
 *
 * # Safety
 * `value` 16 doubles; `point` 3; `out` 3.
 */
bool cadaclysm_blacksmith_rectangle_closest_point(const double *value,
                                                  const double *point,
                                                  bool include_interior,
                                                  double *out);

/**
 * Where `point`, projected onto the rectangle's plane, lies (Rhino's `Contains`):
 * `CADACLYSM_BLACKSMITH_OUTSIDE` (0), `CADACLYSM_BLACKSMITH_INSIDE` (1), or
 * `CADACLYSM_BLACKSMITH_ON` (2) within `tolerance` of the boundary; `CADACLYSM_BLACKSMITH_NONE`
 * and `last_error` on a refusal. `tolerance` NaN is unset, the rectangle's own effective tolerance
 * (`tolerance.relative` times its diagonal, never finer than its coordinates' rounding); 0 is
 * exact (see the tolerances section at `cadaclysm_blacksmith_effective_tolerance`).
 *
 * # Safety
 * `value` 16 doubles; `point` 3.
 */
uint32_t cadaclysm_blacksmith_rectangle_contains(const double *value,
                                                 const double *point,
                                                 double tolerance);

/**
 * The filled rectangle as a one-face planar sheet facing the frame's z, freed with
 * `cadaclysm_blacksmith_solid_free`; NULL and `last_error` on a refusal.
 *
 * # Safety
 * `value` 16 doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rectangle_to_sheet(const double *value);

/**
 * A triangle's area into `out`.
 *
 * # Safety
 * `value` 9 doubles; `out` 1.
 */
bool cadaclysm_blacksmith_triangle_area(const double *value, double *out);

/**
 * A triangle's perimeter into `out`.
 *
 * # Safety
 * `value` 9 doubles; `out` 1.
 */
bool cadaclysm_blacksmith_triangle_perimeter(const double *value, double *out);

/**
 * A triangle's area centroid, the mean of its vertices (Rhino's `AreaCenter`).
 *
 * # Safety
 * `value` 9 doubles; `out` 3.
 */
bool cadaclysm_blacksmith_triangle_centroid(const double *value, double *out);

/**
 * The circle through a triangle's vertices, a kind-1 array: x toward `a`, the normal so `a`,
 * `b`, `c` run counter-clockwise.
 *
 * # Safety
 * `value` 9 doubles; `out` 13.
 */
bool cadaclysm_blacksmith_triangle_circumcircle(const double *value, double *out);

/**
 * The point of barycentric weights `wa`, `wb`, `wc`, used as given (they need not sum to 1).
 *
 * # Safety
 * `value` 9 doubles; `out` 3.
 */
bool cadaclysm_blacksmith_triangle_point_at(const double *value,
                                            double wa,
                                            double wb,
                                            double wc,
                                            double *out);

/**
 * The barycentric weights `wa wb wc` (summing to 1) of `point` projected onto the triangle's
 * plane.
 *
 * # Safety
 * `value` 9 doubles; `point` 3; `out` 3.
 */
bool cadaclysm_blacksmith_triangle_barycentric(const double *value,
                                               const double *point,
                                               double *out);

/**
 * The filled triangle's closest point to `point`, exact (by Voronoi region).
 *
 * # Safety
 * `value` 9 doubles; `point` 3; `out` 3.
 */
bool cadaclysm_blacksmith_triangle_closest_point(const double *value,
                                                 const double *point,
                                                 double *out);

/**
 * Edge `index` as a line value (kind 0): 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`.
 *
 * # Safety
 * `value` 9 doubles; `out` 6.
 */
bool cadaclysm_blacksmith_triangle_edge(const double *value, uint32_t index, double *out);

/**
 * The filled triangle as a one-face planar sheet, its normal turning `a`, `b`, `c`
 * counter-clockwise, freed with `cadaclysm_blacksmith_solid_free`; NULL and `last_error` on a
 * refusal.
 *
 * # Safety
 * `value` 9 doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_triangle_to_sheet(const double *value);

/**
 * A ray's point `position + t * direction`, `t` unbounded (behind the start too).
 *
 * # Safety
 * `value` 6 doubles; `out` 3.
 */
bool cadaclysm_blacksmith_ray_point_at(const double *value, double t, double *out);

/**
 * The ray's closest point to `point`: `t x y z`, `t` clamped at 0 (a point behind the start
 * answers the start).
 *
 * # Safety
 * `value` 6 doubles; `point` 3; `out` 4.
 */
bool cadaclysm_blacksmith_ray_closest_point(const double *value, const double *point, double *out);

/**
 * The least-squares plane through `count` points (`xyz`, three doubles each) as a frame
 * into `out`, and the largest distance any point sits off it into `deviation_out` (NULL
 * when not wanted). z faces world +Z, x by the same rule.
 *
 * # Safety
 * `xyz` `3 * count` doubles; `out` 12; `deviation_out` one double or NULL.
 */
bool cadaclysm_blacksmith_frame_fit(const double *xyz,
                                    size_t count,
                                    double *out,
                                    double *deviation_out);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_BLACKSMITH_H */
