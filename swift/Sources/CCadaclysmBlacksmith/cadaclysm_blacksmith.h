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
 * An offset: 3 numbers a key, composed last into a target's placement.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_TRANSLATE 0

/**
 * Degrees about the track's axis through its pivot (right-handed): 1 number a key.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_ROTATE 1

/**
 * Factors along x, y, z about the track's pivot: 3 numbers a key, composed first.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_SCALE 2

/**
 * Shown when above 0.5: 1 number a key, always read as a step-hold.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_VISIBLE 3

/**
 * Red, green, blue: 3 numbers a key.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_COLOUR 4

/**
 * Drawn see-through when above 0.5: 1 number a key, always read as a step-hold.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_GHOST 5

/**
 * A number or vector the host reads as it likes: any dimension of at least 1.
 */
#define CADACLYSM_BLACKSMITH_CHANNEL_VALUE 6

/**
 * [`cadaclysm_blacksmith_hole`]'s `extent`: through everything ahead of the point.
 */
#define CADACLYSM_BLACKSMITH_HOLE_THROUGH 0

/**
 * `extent`: `depth` of full-diameter bore, then a drill point of `tip_angle`.
 */
#define CADACLYSM_BLACKSMITH_HOLE_BLIND 1

/**
 * `extent`: until the axis first meets face `face`.
 */
#define CADACLYSM_BLACKSMITH_HOLE_TO_FACE 2

/**
 * `extent`: until the bore first leaves the material.
 */
#define CADACLYSM_BLACKSMITH_HOLE_TO_NEXT 3

/**
 * [`cadaclysm_blacksmith_hole`]'s `head`: none.
 */
#define CADACLYSM_BLACKSMITH_HOLE_SIMPLE 0

/**
 * `head`: a wider bore `head_diameter` across and `head_depth` deep.
 */
#define CADACLYSM_BLACKSMITH_HOLE_COUNTERBORE 1

/**
 * `head`: a cone `head_diameter` across at the point, included angle `head_angle`.
 */
#define CADACLYSM_BLACKSMITH_HOLE_COUNTERSINK 2

/**
 * [`cadaclysm_blacksmith_pattern_feature`]'s `op`: cut the tool from the body.
 */
#define CADACLYSM_BLACKSMITH_FEATURE_CUT 0

/**
 * `op`: join the tool to the body.
 */
#define CADACLYSM_BLACKSMITH_FEATURE_JOIN 1

/**
 * [`cadaclysm_blacksmith_rib`]'s `side`: half the thickness each side of the plane.
 */
#define CADACLYSM_BLACKSMITH_RIB_BOTH 0

/**
 * `side`: the thickness on the plane's +z side.
 */
#define CADACLYSM_BLACKSMITH_RIB_FRONT 1

/**
 * `side`: the thickness on the plane's -z side.
 */
#define CADACLYSM_BLACKSMITH_RIB_BACK 2

/**
 * [`cadaclysm_blacksmith_web`]'s `side`: half the thickness each side of the curve.
 */
#define CADACLYSM_BLACKSMITH_WEB_BOTH 0

/**
 * `side`: the thickness left of the curve's run, the plane's normal up.
 */
#define CADACLYSM_BLACKSMITH_WEB_LEFT 1

/**
 * `side`: the thickness right of the curve's run.
 */
#define CADACLYSM_BLACKSMITH_WEB_RIGHT 2

/**
 * [`cadaclysm_blacksmith_pattern_along`]'s `orient`: copies translated only.
 */
#define CADACLYSM_BLACKSMITH_ORIENT_FIXED 0

/**
 * `orient`: copies also turned by the curve's rotation-minimising frame.
 */
#define CADACLYSM_BLACKSMITH_ORIENT_PATH 1

/**
 * A size table row's family (`out[0]` of [`cadaclysm_blacksmith_thread_size_at`]): ISO
 * metric coarse (ISO 261 / 262).
 */
#define CADACLYSM_BLACKSMITH_THREAD_ISO_METRIC_COARSE 0

/**
 * Family: ISO metric fine (ISO 261's usual fine pitches).
 */
#define CADACLYSM_BLACKSMITH_THREAD_ISO_METRIC_FINE 1

/**
 * Family: UNC (ASME B1.1).
 */
#define CADACLYSM_BLACKSMITH_THREAD_UNC 2

/**
 * Family: UNF (ASME B1.1).
 */
#define CADACLYSM_BLACKSMITH_THREAD_UNF 3

/**
 * Thread `flags`: a left-handed thread.
 */
#define CADACLYSM_BLACKSMITH_THREAD_LEFT_HANDED 1

/**
 * `flags`: the span starts from the face's other end.
 */
#define CADACLYSM_BLACKSMITH_THREAD_REVERSE 2

/**
 * `flags`, [`cadaclysm_blacksmith_hole_threaded`]'s only: drill the bore alone and record
 * the thread on it as a cosmetic thread.
 */
#define CADACLYSM_BLACKSMITH_THREAD_COSMETIC 4

/**
 * How many `uint32_t`s [`cadaclysm_blacksmith_from_mesh`] writes to its `report`: closed (1
 * or 0), faces, edges, vertices, holes, boundary edges, non-manifold edges, flipped, dropped,
 * planes, cylinders, cones, spheres, tori.
 */
#define CADACLYSM_BLACKSMITH_FROM_MESH_REPORT_LEN 14

/**
 * [`cadaclysm_blacksmith_from_mesh`]'s `mode`: one planar face per triangle (level 1).
 */
#define CADACLYSM_BLACKSMITH_FROM_MESH_MODE_FACETED 0

/**
 * `mode`: coplanar neighbouring triangles merged into one planar face (level 2).
 */
#define CADACLYSM_BLACKSMITH_FROM_MESH_MODE_PLANES 1

/**
 * `mode`: planes merged as level 2, and curved regions fitted with cylinders, cones, spheres
 * and tori (level 3, the recommended mode).
 */
#define CADACLYSM_BLACKSMITH_FROM_MESH_MODE_PRISMATIC 2

/**
 * A cycloidal pinion leaf's round tip: a semicircle of half the leaf thickness on the pitch
 * circle.
 */
#define CADACLYSM_BLACKSMITH_GEAR_TIP_ROUND 0

/**
 * A cycloidal pinion leaf's ogival tip: the epicycloid of a circle of half the wheel's pitch
 * radius, truncated at `0.855 module`.
 */
#define CADACLYSM_BLACKSMITH_GEAR_TIP_OGIVE 1

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
 * A face whose whole area drafts along `+d` (`CadaclysmBlacksmithFaceDraft`'s `kind`).
 */
#define CADACLYSM_BLACKSMITH_DRAFT_POSITIVE 0

/**
 * A face whose whole area drafts along `-d`.
 */
#define CADACLYSM_BLACKSMITH_DRAFT_NEGATIVE 1

/**
 * A face whose whole area runs along `d`, within the threshold: it needs draft.
 */
#define CADACLYSM_BLACKSMITH_DRAFT_VERTICAL 2

/**
 * A face whose parts fall in different bands.
 */
#define CADACLYSM_BLACKSMITH_DRAFT_MIXED 3

/**
 * A face some of whose area the body shadows along the way it releases.
 */
#define CADACLYSM_BLACKSMITH_DRAFT_UNDERCUT 4

/**
 * The length of the options array, in this order: `particle_distance` (mm), `frame_dt` (s),
 * `substeps` (whole, 1 to 10000), `iterations` (whole, 1 to 10000), `gravity.x`, `gravity.y`,
 * `gravity.z` (mm/s^2), `damping`, `local_damping`, `air_drag`, `air_lift`, `air_density`,
 * `sewing_stiffness`, `sewing_speed`, `weld_distance` (mm), `avatar_thickness` (mm),
 * `self_thickness` (mm), `self_stiffness`, `self_collision` (0 or 1), `drag_stiffness`.
 */
#define CADACLYSM_BLACKSMITH_CLOTH_OPTIONS 20

/**
 * The length of the status array: `{frame, vertices, triangles, seam_pairs, welded_pairs,
 * non_finite, dropped, max_speed}`. `seam_pairs` counts every seam pair in the sim mesh, open
 * or welded: sewing is done when `welded_pairs == seam_pairs`.
 */
#define CADACLYSM_BLACKSMITH_CLOTH_STATUS 8

/**
 * Notch kind: a slit cut into the seam allowance.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_NOTCH_SLIT 0

/**
 * Notch kind: a V cut out of the seam allowance.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_NOTCH_V 1

/**
 * Notch kind: a T-shaped mark.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_NOTCH_T 2

/**
 * Notch kind: a castle (a square tooth).
 */
#define CADACLYSM_BLACKSMITH_GARMENT_NOTCH_CASTLE 3

/**
 * Notch kind: a U cut out of the seam allowance.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_NOTCH_U 4

/**
 * Internal-line kind: a drawn line (a placement or style line).
 */
#define CADACLYSM_BLACKSMITH_GARMENT_INTERNAL_LINE 0

/**
 * Internal-line kind: a fold line.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_INTERNAL_FOLD 1

/**
 * Internal-line kind: a dart.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_INTERNAL_DART 2

/**
 * Issue severity: the garment cannot be used as it is.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_SEVERITY_ERROR 0

/**
 * Issue severity: usable, but probably not what was meant.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_SEVERITY_WARNING 1

/**
 * Issue kind: a pattern names a fabric that does not exist.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_UNKNOWN_FABRIC 0

/**
 * Issue kind: a seam names a pattern that does not exist.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_UNKNOWN_PATTERN 1

/**
 * Issue kind: a pattern's allowance count is not its side count.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_ALLOWANCE_COUNT 2

/**
 * Issue kind: a pattern's grain direction is zero.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_ZERO_GRAIN 3

/**
 * Issue kind: a fabric parameter is negative where it must not be.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_NEGATIVE_FABRIC_VALUE 4

/**
 * Issue kind: a seam allowance is negative.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_NEGATIVE_ALLOWANCE 5

/**
 * Issue kind: a notch lies off its pattern's outline.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_NOTCH_OUT_OF_RANGE 6

/**
 * Issue kind: a seam's range lies off its pattern's outline.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_RANGE_OUT_OF_RANGE 7

/**
 * Issue kind: a seam's range is empty.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_EMPTY_RANGE 8

/**
 * Issue kind: two seams overlap on one pattern.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_SEAM_OVERLAP 9

/**
 * Issue kind: a seam's two sides differ in length (the ratio is in the issue's third number).
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_SEAM_LENGTH_MISMATCH 10

/**
 * Issue kind: an outline's length cannot be measured, or the accuracy is outside (0, 1).
 */
#define CADACLYSM_BLACKSMITH_GARMENT_ISSUE_UNMEASURABLE 11

/**
 * The length of every fabric-parameter array: stretch (warp, weft), shear (left, right),
 * bending (warp, weft, bias left, bias right), buckling ratio (the same four), buckling
 * stiffness (the same four), density, thickness, friction, internal damping.
 */
#define CADACLYSM_BLACKSMITH_GARMENT_FABRIC_PARAMS 20

/**
 * `CadaclysmBlacksmithHlrOptions::projection`: looking along `direction`, every sight
 * line parallel.
 */
#define CADACLYSM_BLACKSMITH_HLR_PARALLEL 0

/**
 * `CadaclysmBlacksmithHlrOptions::projection`: standing at `eye`, looking at `target`.
 */
#define CADACLYSM_BLACKSMITH_HLR_PERSPECTIVE 1

/**
 * `CadaclysmBlacksmithHlrLine::kind`: an edge between faces meeting at an angle.
 */
#define CADACLYSM_BLACKSMITH_HLR_SHARP 0

/**
 * `kind`: an edge between faces tangent across it (a fillet's rim).
 */
#define CADACLYSM_BLACKSMITH_HLR_SMOOTH 1

/**
 * `kind`: a silhouette, where a face turns away from the eye.
 */
#define CADACLYSM_BLACKSMITH_HLR_OUTLINE 2

/**
 * `kind`: an isocurve of a face, drawn only when `iso` asks for them.
 */
#define CADACLYSM_BLACKSMITH_HLR_ISO 3

/**
 * `kind`: an edge with one face, an open sheet's rim.
 */
#define CADACLYSM_BLACKSMITH_HLR_BOUNDARY 4

/**
 * `CadaclysmBlacksmithHlrLine::source_kind`: an edge; `source` is its id.
 */
#define CADACLYSM_BLACKSMITH_HLR_SOURCE_EDGE 0

/**
 * `source_kind`: a face (its silhouette or isocurve); `source` is its index in the solid.
 */
#define CADACLYSM_BLACKSMITH_HLR_SOURCE_FACE 1

/**
 * `source_kind`: a triangle mesh's feature edge; `source` and `source2` are its two
 * vertices (the first edge of the chain the line runs along).
 */
#define CADACLYSM_BLACKSMITH_HLR_SOURCE_MESH_EDGE 2

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
 * `cadaclysm_blacksmith_nurbs_curve_conic_type`: not a conic.
 */
#define CADACLYSM_BLACKSMITH_CONIC_NONE 0

/**
 * A circle.
 */
#define CADACLYSM_BLACKSMITH_CONIC_CIRCLE 1

/**
 * An ellipse (not a circle).
 */
#define CADACLYSM_BLACKSMITH_CONIC_ELLIPSE 2

/**
 * A hyperbola.
 */
#define CADACLYSM_BLACKSMITH_CONIC_HYPERBOLA 3

/**
 * A parabola.
 */
#define CADACLYSM_BLACKSMITH_CONIC_PARABOLA 4

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
 * A bit of `flags`: draw each solid's lines through hidden-line removal, the visible
 * parts only -- the solids on the page hide one another. Edges go in `solid-<i>` when a
 * line set is named and silhouettes in `solid-<i>-silhouettes` when `SILHOUETTES` is, the
 * same groups as without the bit, holding only what is seen. The lines are solved from the
 * eye the options describe, at the page tolerance in model units, and the page is framed
 * as the silhouettes frame it, so the picture is drawn from the eye its lines were solved
 * for. Profiles are drawn as without the bit: they neither hide nor are hidden.
 */
#define CADACLYSM_BLACKSMITH_SVG_HIDDEN_REMOVED 32

/**
 * A bit of `flags`: as `HIDDEN_REMOVED`, and the hidden lines drawn too, dashed, in a
 * `solid-<i>-hidden` group after the solid's others (dashes six stroke widths long, gaps
 * three). Set with `HIDDEN_REMOVED`, this one wins.
 */
#define CADACLYSM_BLACKSMITH_SVG_HIDDEN_DASHED 64

/**
 * `cadaclysm_blacksmith_profile_contains`: the point lies outside the profile.
 */
#define CADACLYSM_BLACKSMITH_CONTAINS_OUTSIDE 0

/**
 * `cadaclysm_blacksmith_profile_contains`: the point lies inside.
 */
#define CADACLYSM_BLACKSMITH_CONTAINS_INSIDE 1

/**
 * `cadaclysm_blacksmith_profile_contains`: the point lies on a loop, within the tolerance.
 */
#define CADACLYSM_BLACKSMITH_CONTAINS_ON 2

/**
 * `cadaclysm_blacksmith_profile_relationship`: no point in common.
 */
#define CADACLYSM_BLACKSMITH_RELATION_DISJOINT 0

/**
 * The boundaries meet; the interiors do not overlap.
 */
#define CADACLYSM_BLACKSMITH_RELATION_TOUCHING 1

/**
 * The interiors overlap and neither region holds the other.
 */
#define CADACLYSM_BLACKSMITH_RELATION_OVERLAPPING 2

/**
 * The first region lies in the second.
 */
#define CADACLYSM_BLACKSMITH_RELATION_A_INSIDE_B 3

/**
 * The second region lies in the first.
 */
#define CADACLYSM_BLACKSMITH_RELATION_B_INSIDE_A 4

/**
 * One region, to the tolerance.
 */
#define CADACLYSM_BLACKSMITH_RELATION_EQUAL 5

/**
 * Offset corner style: an arc of radius `|distance|` about the corner.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_ROUND 0

/**
 * Offset corner style: the sides drawn on along their tangents to meet (chamfered past a
 * miter of 100 `|distance|`).
 */
#define CADACLYSM_BLACKSMITH_OFFSET_SHARP 1

/**
 * Offset corner style: the parabola tangent to both sides.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_SMOOTH 2

/**
 * Offset corner style: a straight line across.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_CHAMFER 3

/**
 * Open offset end style: the one-sided offset, open chains.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_END_NONE 0

/**
 * Open offset end style: the outline round both sides, a line across each end.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_END_FLAT 1

/**
 * Open offset end style: the outline round both sides, a half circle about each end.
 */
#define CADACLYSM_BLACKSMITH_OFFSET_END_ROUND 2

/**
 * `CadaclysmBlacksmithSheetRule::relief`: no bend relief.
 */
#define CADACLYSM_BLACKSMITH_RELIEF_NONE 0

/**
 * A rectangular bend relief.
 */
#define CADACLYSM_BLACKSMITH_RELIEF_RECTANGULAR 1

/**
 * An obround bend relief: a rectangle with a round end.
 */
#define CADACLYSM_BLACKSMITH_RELIEF_ROUND 2

/**
 * A small circle where the bend zone meets the base.
 */
#define CADACLYSM_BLACKSMITH_RELIEF_TEAR 3

/**
 * `CadaclysmBlacksmithSheetRule::corner`: no corner relief.
 */
#define CADACLYSM_BLACKSMITH_CORNER_NONE 0

/**
 * A square corner relief.
 */
#define CADACLYSM_BLACKSMITH_CORNER_SQUARE 1

/**
 * A round corner relief.
 */
#define CADACLYSM_BLACKSMITH_CORNER_ROUND 2

/**
 * A tear-drop corner relief.
 */
#define CADACLYSM_BLACKSMITH_CORNER_TEAR 3

/**
 * `cadaclysm_blacksmith_sheet_hem`'s `kind`: the lip folded flat on the sheet.
 */
#define CADACLYSM_BLACKSMITH_HEM_FLAT 0

/**
 * The lip folded back with a gap.
 */
#define CADACLYSM_BLACKSMITH_HEM_OPEN 1

/**
 * The edge rolled round through an angle.
 */
#define CADACLYSM_BLACKSMITH_HEM_ROLLED 2

/**
 * A tear drop: rolled, its lip back on the sheet.
 */
#define CADACLYSM_BLACKSMITH_HEM_TEARDROP 3

/**
 * A rope hem: curled round a rod `gap` across until it comes back down to the sheet.
 */
#define CADACLYSM_BLACKSMITH_HEM_ROPE 4

/**
 * A double hem: folded twice and pressed flat, three layers.
 */
#define CADACLYSM_BLACKSMITH_HEM_DOUBLE 5

/**
 * `page_add_flat_pattern`'s and `flat_pattern_dxf`'s `flags`: each bend zone's two edges.
 */
#define CADACLYSM_BLACKSMITH_FLAT_EXTENTS 1

/**
 * A ruled table of the bends under the outline: number, direction, angle, inner radius,
 * K-factor, allowance and deduction.
 */
#define CADACLYSM_BLACKSMITH_FLAT_TABLE 2

/**
 * A label on each bend line: its number, direction and angle.
 */
#define CADACLYSM_BLACKSMITH_FLAT_LABELS 4

/**
 * A bend note along each bend line: direction, angle and inner radius (`UP 90° R1`).
 */
#define CADACLYSM_BLACKSMITH_FLAT_NOTES 8

/**
 * The flat's overall width and height dimensioned (drawn as lines, arrowheads and text).
 */
#define CADACLYSM_BLACKSMITH_FLAT_DIMENSIONS 16

/**
 * The folded part's front view right of the flat, at the flat's scale.
 */
#define CADACLYSM_BLACKSMITH_FLAT_FOLDED 32

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
 * Constraint kind: two curves joined end to end with matching tangent and curvature
 * (refs: curve, curve).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_SMOOTH 27

/**
 * Constraint kind: `b - a` held equal to `to - from`, a pattern's hold (refs: a, b,
 * from, to; all points).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TRANSLATED 28

/**
 * Constraint kind: `b` held at `a` turned about `centre` by the turn from `from` to
 * `to`, a pattern's hold (refs: a, b, centre, from, to; all points).
 */
#define CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_ROTATED 29

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
 * `cadaclysm_blacksmith_squish`'s `deformation`: no preference for stretching or compressing.
 */
#define CADACLYSM_BLACKSMITH_SQUISH_FREE 0

/**
 * A strong bias for flat lengths shorter than their 3D lengths (the pattern stretches over the
 * shape).
 */
#define CADACLYSM_BLACKSMITH_SQUISH_STRETCH_MOSTLY 1

/**
 * Every flat length at most its 3D length.
 */
#define CADACLYSM_BLACKSMITH_SQUISH_STRETCH_ONLY 2

/**
 * A strong bias for flat lengths longer than their 3D lengths (the pattern compresses onto the
 * shape).
 */
#define CADACLYSM_BLACKSMITH_SQUISH_COMPRESS_MOSTLY 3

/**
 * Every flat length at least its 3D length.
 */
#define CADACLYSM_BLACKSMITH_SQUISH_COMPRESS_ONLY 4

/**
 * [`cadaclysm_blacksmith_solid_untrim`]'s `which`: the face's holes (inner loops) go.
 */
#define CADACLYSM_BLACKSMITH_UNTRIM_HOLES 0

/**
 * [`cadaclysm_blacksmith_solid_untrim`]'s `which`: the outer boundary becomes the surface's
 * natural one; the holes stay.
 */
#define CADACLYSM_BLACKSMITH_UNTRIM_OUTER 1

/**
 * [`cadaclysm_blacksmith_solid_untrim`]'s `which`: both -- the face becomes its surface's
 * natural patch.
 */
#define CADACLYSM_BLACKSMITH_UNTRIM_ALL 2

/**
 * [`cadaclysm_blacksmith_solid_ruled_from_edges`]'s `kind`: square to the edge in its face's
 * tangent plane, away from the face -- the face carried on past its edge.
 */
#define CADACLYSM_BLACKSMITH_RULING_TANGENT 0

/**
 * [`cadaclysm_blacksmith_solid_ruled_from_edges`]'s `kind`: along the face's outward normal.
 */
#define CADACLYSM_BLACKSMITH_RULING_NORMAL 1

/**
 * [`cadaclysm_blacksmith_solid_ruled_from_edges`]'s `kind`: along (`x`, `y`, `z`), normalised
 * and not made square to the edge.
 */
#define CADACLYSM_BLACKSMITH_RULING_DIRECTION 2

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
 * [`cadaclysm_blacksmith_fillet_rule`]'s `rule`: convex and concave edges both.
 */
#define CADACLYSM_BLACKSMITH_EDGE_RULE_ALL 0

/**
 * `rule`: the concave edges only (valleys).
 */
#define CADACLYSM_BLACKSMITH_EDGE_RULE_CONCAVE 1

/**
 * `rule`: the convex edges only (ridges).
 */
#define CADACLYSM_BLACKSMITH_EDGE_RULE_CONVEX 2

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
 * Keyframe tracks over named targets. Opaque; free with
 * [`cadaclysm_blacksmith_animation_free`].
 *
 * Beside the animation, one C string per track's target and one per target, in lists that only
 * grow (each string its own allocation), so a borrowed name outlives every later `_add_track`.
 */
typedef struct CadaclysmBlacksmithAnimation CadaclysmBlacksmithAnimation;

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
 * What a check found, read one finding at a time. Immutable; free with
 * [`cadaclysm_blacksmith_check_free`].
 */
typedef struct CadaclysmBlacksmithCheck CadaclysmBlacksmithCheck;

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
 * A cloth simulation: a garment's patterns meshed into particles, sewn along its seams and
 * draped on an avatar. A mutable object: one thread at a time. Free it with
 * [`cadaclysm_blacksmith_cloth_free`].
 */
typedef struct CadaclysmBlacksmithCloth CadaclysmBlacksmithCloth;

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
 * An owned list of curves with their facts, from `cadaclysm_blacksmith_nurbs_curve_face_isocurves`,
 * `cadaclysm_blacksmith_solid_section_curves` and `cadaclysm_blacksmith_solid_contour_curves`.
 * Read with `cadaclysm_blacksmith_curve_list_count`, `_curve` and `_info`; free with
 * `cadaclysm_blacksmith_curve_list_free`.
 */
typedef struct CadaclysmBlacksmithCurveList CadaclysmBlacksmithCurveList;

/**
 * A blacksmith document: nodes, parameters, history, branches and an evaluation cache. A
 * mutable object, like `CadaclysmBlacksmithSketch`: one thread at a time. Free it with
 * [`cadaclysm_blacksmith_document_free`].
 */
typedef struct CadaclysmBlacksmithDocument CadaclysmBlacksmithDocument;

/**
 * Every face's draft over a body, read one face at a time; free with
 * [`cadaclysm_blacksmith_draft_analysis_free`]. Immutable.
 */
typedef struct CadaclysmBlacksmithDraftAnalysis CadaclysmBlacksmithDraftAnalysis;

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
 * A sheet body laid flat ([`cadaclysm_blacksmith_flat_pattern`]): the flat body, its outline,
 * its frame, the bend zones and the part's bends. Immutable; free with
 * [`cadaclysm_blacksmith_flat_pattern_free`].
 */
typedef struct CadaclysmBlacksmithFlatPattern CadaclysmBlacksmithFlatPattern;

/**
 * A garment: patterns, the seams that join them and their fabrics. A mutable object, like
 * `CadaclysmBlacksmithSketch`: one thread at a time. Free it with
 * [`cadaclysm_blacksmith_garment_free`].
 */
typedef struct CadaclysmBlacksmithGarment CadaclysmBlacksmithGarment;

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
 * A view's lines: immutable, safe to read from any number of threads at once. Free with
 * [`cadaclysm_blacksmith_hlr_free`].
 */
typedef struct CadaclysmBlacksmithHlr CadaclysmBlacksmithHlr;

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
 * An untrimmed NURBS surface, exact and immutable: any number of nearest points and curves are
 * answered exactly against it (no tolerance, no `refined` figure). Its Bezier patches are cut
 * once, at the first query, and kept. Opaque; free with
 * [`cadaclysm_blacksmith_nurbs_surface_free`].
 *
 * Nothing in it changes after it is built but that one-time cut, which is safe to race, so
 * calls on one surface from several threads at once are safe.
 */
typedef struct CadaclysmBlacksmithNurbsSurface CadaclysmBlacksmithNurbsSurface;

/**
 * Every operation of a job, read back in order -- see
 * [`cadaclysm_blacksmith_job_operations`]. Immutable; free with
 * [`cadaclysm_blacksmith_operations_free`].
 */
typedef struct CadaclysmBlacksmithOperations CadaclysmBlacksmithOperations;

/**
 * A drawing page. Mutable: not for two threads at once. Free with
 * [`cadaclysm_blacksmith_page_free`].
 */
typedef struct CadaclysmBlacksmithPage CadaclysmBlacksmithPage;

/**
 * An outline under construction: a start point and the segments drawn so far.
 * A mutable object, like `CadaclysmBlacksmithSweepPath` and
 * `CadaclysmBlacksmithAssembly`; unlike them, [`cadaclysm_blacksmith_path_end`]
 * consumes this one rather than leaving it live to be added to again.
 */
typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

/**
 * A set of polygons in the plane. Opaque; free with [`cadaclysm_blacksmith_polygon_set_free`].
 */
typedef struct CadaclysmBlacksmithPolygonSet CadaclysmBlacksmithPolygonSet;

/**
 * Polylines, as [`cadaclysm_blacksmith_polygon_set_clip_polyline`] hands them out. Opaque; free
 * with [`cadaclysm_blacksmith_polygon_set_lines_free`].
 */
typedef struct CadaclysmBlacksmithPolygonSetLines CadaclysmBlacksmithPolygonSetLines;

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
 * A solid meshed, indexed and its faces prepared once, ready to answer any number of nearest
 * points. Opaque; free with [`cadaclysm_blacksmith_projector_free`].
 *
 * It keeps its own reference to the body, so the solid it was built from may be freed first.
 * Build one per body for many points: [`cadaclysm_blacksmith_closest_point`] meshes the body on
 * every call.
 */
typedef struct CadaclysmBlacksmithProjector CadaclysmBlacksmithProjector;

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
 * A recognition report and the recognised solid: owned data, opaque, independent of the solid
 * it was made from (it stays good after
 * [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free)). Made by
 * [`cadaclysm_blacksmith_recognized`], freed with [`cadaclysm_blacksmith_recognize_free`].
 */
typedef struct CadaclysmBlacksmithRecognize CadaclysmBlacksmithRecognize;

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
 * Faces of a solid squished flat ([`cadaclysm_blacksmith_squish`]): the flat sheet, each of
 * its faces' source face and distortion, the faces laid exactly, the curves and points
 * followed. Immutable; free with [`cadaclysm_blacksmith_squished_free`].
 */
typedef struct CadaclysmBlacksmithSquished CadaclysmBlacksmithSquished;

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
 * A triangle mesh and its search tree, built once and immutable: any number of nearest points
 * and curves are answered exactly against it (no tolerance, no `refined` figure). Opaque; free
 * with [`cadaclysm_blacksmith_triangle_mesh_free`].
 *
 * Nothing in it changes after it is built, so calls on one mesh from several threads at once
 * are safe and do not serialise.
 */
typedef struct CadaclysmBlacksmithTriangleMesh CadaclysmBlacksmithTriangleMesh;

/**
 * Faces of a solid laid flat ([`cadaclysm_blacksmith_unroll`]): the flat sheet, each of its
 * faces' source face, the curves and points followed, the faces not developable and the
 * edges cut. Immutable; free with [`cadaclysm_blacksmith_unrolled_free`].
 */
typedef struct CadaclysmBlacksmithUnrolled CadaclysmBlacksmithUnrolled;

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
 * A gear's key circles and thickness, written by the `cadaclysm_blacksmith_profile_gear_*`
 * calls on success only. `base_radius` is NaN for cycloidal gearing; `tip_radius` is the
 * largest radius on the profile and `root_radius` the smallest; `thickness` is the tooth
 * (leaf) thickness on the pitch circle, as an arc length; `undercut` (involute only) says
 * undercut would occur -- it is not drawn.
 */
typedef struct CadaclysmBlacksmithGearReport {
  double pitch_radius;
  double base_radius;
  double tip_radius;
  double root_radius;
  double thickness;
  bool undercut;
} CadaclysmBlacksmithGearReport;

/**
 * Where `cadaclysm_blacksmith_contact_settle` left the follower, written on success only.
 * `value` is the follower's resting angle, never penetrating; `contact` says it touches the
 * driver (the gap within the tolerance) rather than stopped at the limit; `recoiled` says it
 * started penetrating and was pushed back against the direction. `point_x`, `point_y` is the
 * midpoint of the closest pair and `normal_x`, `normal_y` the unit contact normal from the
 * driver toward the follower, all NaN without contact. `driver_loop`, `driver_segment`,
 * `follower_loop` and `follower_segment` name the touching segments (loop 0 the outer, 1.. the
 * holes in order; the segment an index into that loop's), `UINT32_MAX` without contact.
 * `steps` counts the gap evaluations spent.
 */
typedef struct CadaclysmBlacksmithSettle {
  double value;
  bool contact;
  bool recoiled;
  double point_x;
  double point_y;
  double normal_x;
  double normal_y;
  uint32_t driver_loop;
  uint32_t driver_segment;
  uint32_t follower_loop;
  uint32_t follower_segment;
  uint32_t steps;
} CadaclysmBlacksmithSettle;

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
 * Where [`cadaclysm_blacksmith_document_evaluate_with`] reports: `node` the id of the node
 * being built, `phase` a short static name ("snap", "clip", ...), `done` of `total` steps
 * within it, `user` whatever was passed in. As [`CadaclysmBlacksmithProgress`](crate::CadaclysmBlacksmithProgress):
 * called on the calling thread, often, so a sink that forwards elsewhere throttles itself;
 * it must not call back into this library. The strings are valid for the call only. Null
 * means silent.
 */
typedef void (*CadaclysmBlacksmithDocumentProgress)(const char *node,
                                                    const char *phase,
                                                    size_t done,
                                                    size_t total,
                                                    void *user);

/**
 * Where a long operation reports: `phase` is a short static name ("snap",
 * "clip", ...), `done` of `total` steps within it, `user` whatever was passed
 * in. Called on the calling thread, often -- once per vertex in some phases --
 * so a sink that forwards elsewhere throttles itself. Must not call back into
 * this library. Null means silent.
 */
typedef void (*CadaclysmBlacksmithProgress)(const char *phase, size_t done, size_t total, void *user);

/**
 * A point of a face and the draft angle there (`cadaclysm_blacksmith_draft_angle_at`): the
 * point on the face, the surface parameters the normal was read at (both NaN where there are
 * none), the face's outward unit normal there, and `angle`, `asin(normal . d)` in radians.
 */
typedef struct CadaclysmBlacksmithDraftPoint {
  double point[3];
  double uv[2];
  double normal[3];
  double angle;
} CadaclysmBlacksmithDraftPoint;

/**
 * One face's draft over a body (`cadaclysm_blacksmith_draft_analysis_face`), every angle in
 * radians and every area the face's measuring mesh's: `face` its index, `min` and `max` the
 * least and greatest angle over its samples, `area` its whole area (0 for a sliver narrower
 * than the mesh), `positive` the area at least `+threshold`, `negative` at most `-threshold`,
 * `vertical` within it, `undercut` the area whose release ray meets the body, and `kind` one
 * of `CADACLYSM_BLACKSMITH_DRAFT_POSITIVE` ... `_UNDERCUT`: undercut where any area is, else
 * the band that holds the whole face, else mixed.
 */
typedef struct CadaclysmBlacksmithFaceDraft {
  uint32_t face;
  double min;
  double max;
  double area;
  double positive;
  double negative;
  double vertical;
  double undercut;
  uint32_t kind;
} CadaclysmBlacksmithFaceDraft;

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
   * `cadaclysm_node_fem_mesh` sets it for a node with no brep (an STL, an OpenSCAD
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
 * How the solids are seen and what is drawn. `size` is
 * `sizeof(CadaclysmBlacksmithHlrOptions)`; fill it with
 * [`cadaclysm_blacksmith_hlr_options_init`] and change what you need.
 */
typedef struct CadaclysmBlacksmithHlrOptions {
  uint32_t size;
  /**
   * `CADACLYSM_BLACKSMITH_HLR_PARALLEL` (the default) or `..._PERSPECTIVE`.
   */
  uint32_t projection;
  /**
   * Parallel: the view direction, from the eye toward the model; any length but 0.
   * Default (0, 1, 0): the front, looking from -Y.
   */
  double direction[3];
  /**
   * The page's up, both projections: any vector not along the view. Default (0, 0, 1).
   */
  double up[3];
  /**
   * Perspective: where the eye stands.
   */
  double eye[3];
  /**
   * Perspective: what it looks at.
   */
  double target[3];
  /**
   * Model units: how far a line may stray from the true curve. 0 (the default) or NaN:
   * the solids' effective tolerance (see
   * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance));
   * for meshes, a ten-thousandth of the largest mesh's extent.
   */
  double tolerance;
  /**
   * Radians: faces within this of tangent across an edge make it smooth. Default one
   * degree.
   */
  double smooth_angle;
  /**
   * Radians, meshes only: an edge whose two triangles turn by more than this is drawn.
   * Default thirty degrees.
   */
  double feature_angle;
  /**
   * Isocurves per direction on each face; 0 (the default) draws none. At most 1000.
   */
  uint32_t iso;
  /**
   * Zero.
   */
  uint32_t reserved;
} CadaclysmBlacksmithHlrOptions;

/**
 * One line of a view: what it is, whether it is seen, what it is a span of, and how many
 * Béziers draw it. Read with [`cadaclysm_blacksmith_hlr_line`].
 */
typedef struct CadaclysmBlacksmithHlrLine {
  /**
   * `CADACLYSM_BLACKSMITH_HLR_SHARP` .. `..._BOUNDARY`.
   */
  uint32_t kind;
  /**
   * 1 seen, 0 hidden.
   */
  uint32_t visible;
  /**
   * Which of the solids (or meshes) given it belongs to, from 0.
   */
  uint32_t solid;
  /**
   * `CADACLYSM_BLACKSMITH_HLR_SOURCE_EDGE`, `..._FACE` or `..._MESH_EDGE`.
   */
  uint32_t source_kind;
  /**
   * The edge id, the face index, or a mesh edge's first vertex.
   */
  uint32_t source;
  /**
   * A mesh edge's second vertex; `CADACLYSM_BLACKSMITH_NONE` otherwise.
   */
  uint32_t source2;
  /**
   * How many Béziers [`cadaclysm_blacksmith_hlr_line_beziers2d`] and
   * [`cadaclysm_blacksmith_hlr_line_beziers3d`] each write.
   */
  uint32_t bezier_count;
  /**
   * Zero.
   */
  uint32_t reserved;
  /**
   * Its length on the view plane.
   */
  double length2d;
  /**
   * Its length in space, model units.
   */
  double length3d;
} CadaclysmBlacksmithHlrLine;

/**
 * What a view's hidden-line removal did. Read with [`cadaclysm_blacksmith_hlr_report`].
 */
typedef struct CadaclysmBlacksmithHlrReport {
  /**
   * Curves considered: edges, silhouettes, isocurves (mesh feature chains).
   */
  uint32_t candidates;
  /**
   * View-plane Béziers they projected to.
   */
  uint32_t segments;
  /**
   * Split points kept, over all segments.
   */
  uint32_t crossings;
  /**
   * Pieces classified.
   */
  uint32_t pieces;
  /**
   * Pieces shorter than the tolerance on the view plane (an edge seen end-on): not drawn.
   */
  uint32_t degenerate;
  /**
   * Rays cast toward the eye.
   */
  uint32_t rays;
  /**
   * Mesh triangles those rays met beyond the piece's own point.
   */
  uint32_t mesh_hits;
  /**
   * Mesh hits the exact face rejected.
   */
  uint32_t rejected;
  /**
   * Mesh hits where the ray runs along the surface.
   */
  uint32_t grazes;
  /**
   * Pieces the evidence could not settle, decided by two more samples.
   */
  uint32_t unsettled;
  /**
   * Hits taken on the mesh's word: a face with no surface or no readable trims.
   */
  uint32_t mesh_only;
  /**
   * Edges with no exact curve, drawn from their polyline.
   */
  uint32_t fallback_edges;
  /**
   * Solids that could not be placed or meshed, and so neither draw nor hide.
   */
  uint32_t failed_solids;
  /**
   * Zero.
   */
  uint32_t reserved;
  /**
   * The candidates' total length in space.
   */
  double candidate_length;
  /**
   * The space length of the degenerate pieces.
   */
  double degenerate_length;
  /**
   * The tolerance worked at, model units (0 resolved).
   */
  double tolerance;
} CadaclysmBlacksmithHlrReport;

/**
 * One thing wrong with one argument, copied out of a check result. `kind` names it (a
 * static string, valid for the library's life): `"no_faces"`, `"open"`,
 * `"region_wall"`, `"non_manifold"`, `"face_kind"`, `"short_edge"`,
 * `"collapsed_edge"`, `"sliver_face"`, `"tiny_face"`, `"tiny_body"`, `"small_hole"`,
 * `"loose_edge"`, `"curve_on_surface"`, `"c0_inside"`, `"self_intersection"`,
 * `"self_overlap"`, `"unmeshable"`, `"merge_vertex"`, `"merge_edge"`, `"merge_face"` or
 * `"tangent_face"`.
 * `argument` is 0 for the first solid, 1 for the second (0 for the four kinds on the pair). `index`, `other` and `size`
 * are what the kind gives -- see [`cadaclysm_blacksmith_check`] -- and
 * `CADACLYSM_BLACKSMITH_NONE`, `CADACLYSM_BLACKSMITH_NONE` and 0 where it gives none.
 */
typedef struct CadaclysmBlacksmithFinding {
  const char *kind;
  uint32_t argument;
  uint32_t index;
  uint32_t other;
  double size;
} CadaclysmBlacksmithFinding;

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
 * Where a point lies against a face: `point` its nearest point of the face (inside the trims or
 * on their boundary), `uv` that point's parameters on the face's surface, `distance` from the
 * asked point to it, and `where` 0 inside, 1 on the boundary (on an edge or a vertex of the
 * face, or within the tolerance of one), 2 off (farther than the tolerance).
 */
typedef struct CadaclysmBlacksmithFacePoint {
  double point[3];
  double uv[2];
  double distance;
  uint32_t where;
} CadaclysmBlacksmithFacePoint;

/**
 * The nearest point of an edge's curve over its range: `point`, `t` the curve's own parameter
 * there (the one `edge_curve` and `edge_closest_point` use), `distance` from the asked point, and
 * `on` where that is within the tolerance.
 */
typedef struct CadaclysmBlacksmithEdgePoint {
  double point[3];
  double t;
  double distance;
  bool on;
} CadaclysmBlacksmithEdgePoint;

/**
 * How an edge's two faces meet along it: `kind` 0 smooth (within the angular tolerance of
 * tangent everywhere), 1 convex (a ridge), 2 concave (a valley), 3 mixed (both along it), 4 open
 * (one face, or three and more nowhere two at a time); the smallest and largest signed turn
 * between the faces' outward normals found (radians: positive convex, negative concave) and
 * where; the points asked (0 for an open edge or a closed surface's seam).
 */
typedef struct CadaclysmBlacksmithEdgeConvexity {
  uint32_t kind;
  double angle_min;
  double angle_max;
  double at_min[3];
  double at_max[3];
  uint32_t samples;
} CadaclysmBlacksmithEdgeConvexity;

/**
 * The angle between two entities (radians), a point on each where it is read, and `kind` what
 * they were read as: 0 two planes (the angle between the outward normals, 0 to pi), 1 two lines
 * (between the directions, 0 to pi), 2 a line and a plane (the line's angle to the plane, 0 to
 * pi/2).
 */
typedef struct CadaclysmBlacksmithAngle {
  double angle;
  double at_a[3];
  double at_b[3];
  uint32_t kind;
} CadaclysmBlacksmithAngle;

/**
 * A face's smallest radius of curvature, `1 / max(|k1|, |k2|)` (+inf for a plane); `curvature`
 * that principal curvature signed about the face's outward normal (positive where the face bends
 * away from it: a boss's side; negative toward it: a bore's wall); `at` and `uv` where;
 * `direction` its unit principal direction; `samples` the grid stations read inside the trims
 * (0 where a closed form answered).
 */
typedef struct CadaclysmBlacksmithMinimumRadius {
  double radius;
  double curvature;
  double at[3];
  double uv[2];
  double direction[3];
  uint32_t samples;
} CadaclysmBlacksmithMinimumRadius;

/**
 * A profile's area properties, in the profile's own plane: the area, its perimeter (every loop),
 * the centroid; `second_moments` `[Ixx, Iyy, Ixy]` about the centroid -- `Ixx` about the axis
 * parallel to x, and `Ixy` the product `integral (x - cx)(y - cy) dA` itself, **not negated**
 * (unlike `cadaclysm_blacksmith_mass_properties`' inertia, which negates products);
 * `principal_moments` ascending, `principal_axes` their two unit axes `[x0, y0, x1, y1]` (the
 * second the first turned +90 degrees); each `*_error` the bound the integration reached, and
 * `accuracy_met` whether every bound is within the accuracy asked.
 */
typedef struct CadaclysmBlacksmithAreaProperties {
  double area;
  double area_error;
  double perimeter;
  double centroid[2];
  double centroid_error;
  double second_moments[3];
  double moments_error;
  double principal_moments[2];
  double principal_axes[4];
  bool accuracy_met;
} CadaclysmBlacksmithAreaProperties;

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
 * The nearest point of a solid (or of one face) to a query point, and what it lies on.
 *
 * `distance` is `|point - p|`; `point` lies on the body's **boundary** (a point inside a closed
 * body is answered by its nearest boundary point, not 0). `kind` is a static string, `"face"`,
 * `"edge"` or `"vertex"` (never freed). `index` is the kernel id: the face index, the edge id (a
 * `FemEdge` id) or the topology vertex index. `edge` is, for an edge, the index into the list
 * `cadaclysm_blacksmith_edge` walks -- what `edge_length`, `fillet`, `chamfer` and
 * `edge_closest_point` take, so **read `edge`, not `index`, for the public edge number** -- and
 * `CADACLYSM_BLACKSMITH_NONE` for a face, a vertex, and an edge with no row there (one the brep
 * holds without an exact curve).
 *
 * `uv` is the face parameter of a foot inside a face, NaN in both slots otherwise (an edge or a
 * vertex foot). `normal` is unit: a face foot's outward normal; an edge or vertex foot's
 * direction from the foot to the query point; on the body (`distance` 0) the mean of the
 * adjacent faces' outward normals.
 *
 * `refined` is 1 when the foot was refined onto the exact geometry: `distance` is then never
 * below the true minimum and within the tolerance of it. It is 0 for the mesh's answer: the
 * distance is then within `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`, and
 * `point` lies on the mesh, within a third of the tolerance of the body.
 */
typedef struct CadaclysmBlacksmithPointFoot {
  double distance;
  double point[3];
  const char *kind;
  uint32_t index;
  uint32_t edge;
  double uv[2];
  double normal[3];
  int32_t refined;
} CadaclysmBlacksmithPointFoot;

/**
 * The closest points of two curves: `t_a`/`point_a` on the curve asked (the first argument),
 * `t_b`/`point_b` on the other, `distance` between them (0 where they cross). Among equal
 * distances the smallest `t_a`, then `t_b`, answers.
 */
typedef struct CadaclysmBlacksmithCurvePair {
  double distance;
  double t_a;
  double point_a[3];
  double t_b;
  double point_b[3];
} CadaclysmBlacksmithCurvePair;

/**
 * The nearest points of a curve and a solid's boundary: `t` and `point_on_curve` on the curve,
 * `distance` from there to the body, and `body` the point query's foot at `point_on_curve`,
 * worded exactly as `cadaclysm_blacksmith_closest_point` words it (`kind`, `index` the kernel
 * id, **read `body.edge` for the public edge number**, `uv`, `normal`, and `refined` -- this
 * answer's: 0 means `distance` is within `[d - 2/3 tolerance, d + tolerance]` of the true
 * minimum `d`).
 *
 * `crossing` is 1 where the curve passes through the boundary: `distance` is then exactly 0,
 * the earliest crossing in `t` answers, and `body.distance` is the point query's own figure
 * there (about `1e-12`). 0 otherwise.
 */
typedef struct CadaclysmBlacksmithCurveBodyFoot {
  double distance;
  double t;
  double point_on_curve[3];
  struct CadaclysmBlacksmithPointFoot body;
  int32_t crossing;
} CadaclysmBlacksmithCurveBodyFoot;

/**
 * The nearest point of a triangle mesh (`cadaclysm_blacksmith_triangle_mesh_closest_point`):
 * `point` on the mesh, `distance` to it, and `triangle` the lowest-numbered triangle holding
 * the point -- where it lies on an edge or a vertex several triangles share, the lower
 * triangle answers.
 *
 * `kind` is the feature the point lies on: 0 a face (inside `triangle`), 1 an edge, 2 a
 * vertex. `vertices` names it: an edge's two vertex indices ascending (kind 1), the vertex and
 * then `UINT32_MAX` (kind 2); `UINT32_MAX` marks an unused slot, so a face's are both
 * `UINT32_MAX`. `barycentric` are the point's weights on `triangle`'s three corners in index
 * order, summing to 1.
 */
typedef struct CadaclysmBlacksmithMeshPoint {
  double point[3];
  double distance;
  uint32_t triangle;
  uint32_t kind;
  double barycentric[3];
  uint32_t vertices[2];
} CadaclysmBlacksmithMeshPoint;

/**
 * The nearest points of a curve and a triangle mesh
 * (`cadaclysm_blacksmith_triangle_mesh_curve_closest_points`): `t` and `point_on_curve` on the
 * curve, `mesh` the foot on the mesh, worded as `CadaclysmBlacksmithMeshPoint` words it, and
 * `distance` between them. Exact: no tolerance, no `refined` figure.
 *
 * `crossing` is 1 where the curve passes through the mesh: `distance` is then exactly 0 and
 * the earliest crossing in `t` answers. Among equal distances the lower triangle, then the
 * lower `t`, answers. 0 otherwise.
 */
typedef struct CadaclysmBlacksmithCurveMeshFoot {
  double distance;
  double t;
  double point_on_curve[3];
  struct CadaclysmBlacksmithMeshPoint mesh;
  int32_t crossing;
} CadaclysmBlacksmithCurveMeshFoot;

/**
 * The nearest point of an untrimmed NURBS surface
 * (`cadaclysm_blacksmith_nurbs_surface_closest_point`): `point` on the surface, `distance` to
 * it, and `u`, `v` its parameters. Exact: no tolerance, no `refined` figure. Among equal
 * distances the lower `u`, then the lower `v`, answers.
 *
 * `normal` is the surface's unit normal at `(u, v)` (`dS/du x dS/dv`), all zeros where the
 * partials are parallel (a pole). `boundary` is 1 where the point lies on an edge of the
 * patch (`u` or `v` at an end of the domain) and the way to the query point is not along the
 * normal -- the edge, not the surface's interior, is what is nearest; 0 otherwise.
 */
typedef struct CadaclysmBlacksmithSurfacePoint {
  double point[3];
  double distance;
  double u;
  double v;
  double normal[3];
  int32_t boundary;
} CadaclysmBlacksmithSurfacePoint;

/**
 * The nearest points of a curve and an untrimmed NURBS surface
 * (`cadaclysm_blacksmith_nurbs_surface_curve_closest_points`): `t` and `point_on_curve` on the
 * curve, `surface` the foot on the surface, worded as `CadaclysmBlacksmithSurfacePoint` words
 * it (its `distance` is this one's), and `distance` between them. Exact: no tolerance, no
 * `refined` figure.
 *
 * `crossing` is 1 where the curve passes through the surface: `distance` is then exactly 0 and
 * the earliest meeting in `t` answers. A curve that touches the surface without passing
 * through it answers `distance` 0 and `crossing` 0. Among equal distances the lower `u`, then
 * the lower `v`, then the lower `t` answers.
 */
typedef struct CadaclysmBlacksmithCurveSurfaceFoot {
  double distance;
  double t;
  double point_on_curve[3];
  struct CadaclysmBlacksmithSurfacePoint surface;
  int32_t crossing;
} CadaclysmBlacksmithCurveSurfaceFoot;

/**
 * The nearest item of a set to a curve (`cadaclysm_blacksmith_nurbs_curve_closest_object`):
 * `which` its index into `kinds`, `distance`, the curve's `t` and `point_on_curve`, and the
 * nearest `point_on_item`.
 *
 * `answer_kind` says which member carries the item's own answer: 0 a body (a solid or a
 * projector) -- `body` is filled as `cadaclysm_blacksmith_curve_closest_points` fills it (read
 * `body.body.edge` for the public edge number); 1 a curve -- `pair` is filled as
 * `cadaclysm_blacksmith_nurbs_curve_closest_points(curve, item)` fills it, `t_a`/`point_a` on
 * the curve asked; 2 a point -- neither; 3 a triangle mesh -- `mesh` is filled as
 * `cadaclysm_blacksmith_triangle_mesh_curve_closest_points` fills it; 4 an untrimmed NURBS
 * surface -- `surface` is filled as `cadaclysm_blacksmith_nurbs_surface_curve_closest_points`
 * fills it. The values 0 to 3 are unchanged from before surfaces joined the set. Every field
 * of a member `answer_kind` does not name is zero (`body.body.kind` null, and
 * `mesh.mesh.vertices` 0 rather than `UINT32_MAX`).
 */
typedef struct CadaclysmBlacksmithNearestObject {
  uint32_t which;
  int32_t answer_kind;
  double distance;
  double t;
  double point_on_curve[3];
  double point_on_item[3];
  struct CadaclysmBlacksmithCurveBodyFoot body;
  struct CadaclysmBlacksmithCurvePair pair;
  struct CadaclysmBlacksmithCurveMeshFoot mesh;
  struct CadaclysmBlacksmithCurveSurfaceFoot surface;
} CadaclysmBlacksmithNearestObject;

/**
 * A surface's bending at a point (`cadaclysm_blacksmith_nurbs_surface_curvature`), signed about
 * `normal` (`dS/du x dS/dv`, unit): a curvature is positive where the surface bends toward the
 * normal. `k1 >= k2` are the principal curvatures, `dir1` and `dir2` their unit tangent
 * directions (any orthonormal pair at an umbilic), `gaussian = k1 * k2`, `mean = (k1 + k2) / 2`.
 */
typedef struct CadaclysmBlacksmithSurfaceCurvature {
  double k1;
  double k2;
  double dir1[3];
  double dir2[3];
  double gaussian;
  double mean;
  double normal[3];
} CadaclysmBlacksmithSurfaceCurvature;

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
 * How smoothly a curve runs through its own knots (a closed curve's seam among them): the
 * largest turn of its tangent in radians (`angle`) and the largest jump of its curvature vector
 * `kappa * normal` (`curvature`), each with the parameter and the point it was found at. A
 * curve with no inner knot reads zero at its start.
 */
typedef struct CadaclysmBlacksmithKnotContinuity {
  double angle;
  double angle_parameter;
  double angle_at[3];
  double curvature;
  double curvature_parameter;
  double curvature_at[3];
} CadaclysmBlacksmithKnotContinuity;

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
 * Where a face's Gaussian and mean curvature change sign: how many separate areas of each sign
 * the sample grid finds for each, how many points it found between opposite signs
 * (`cadaclysm_blacksmith_curvature_turn_points` lists them), and the grid's steps each way. A
 * dome or a saddle reads one area of one sign and no turn; a sheet whose sections wobble reads
 * several areas and the turns between them. A sample within a millionth of the face's size of
 * flat counts as neither sign.
 */
typedef struct CadaclysmBlacksmithCurvatureTurns {
  uint32_t gaussian_positive;
  uint32_t gaussian_negative;
  uint32_t gaussian_turns;
  uint32_t mean_positive;
  uint32_t mean_negative;
  uint32_t mean_turns;
  uint32_t samples;
} CadaclysmBlacksmithCurvatureTurns;

/**
 * The worst kink of the highlight lines crossing an edge: the angle in radians (0 to pi/2)
 * between a line on one face and the same line on the other where they meet, where along the
 * edge it is, and the light that shows it -- a straight tube through `light_point` along
 * `light_direction` (unit) -- and how many points along the edge were read.
 */
typedef struct CadaclysmBlacksmithHighlightKink {
  double angle;
  double at[3];
  double light_point[3];
  double light_direction[3];
  uint32_t samples;
} CadaclysmBlacksmithHighlightKink;

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
 * The facts beside a curve in a [`CadaclysmBlacksmithCurveList`]: `plane` the contour plane
 * it lies in (0 for a single section and for isocurves); `closed` 1 where it comes back to its
 * start; `exact` 1 where every piece of it was an exact curve (a chain's line, circle, ellipse
 * or NURBS, a face's edge, a surface's own isocurve); `error` its fit error, 0 where exact.
 */
typedef struct CadaclysmBlacksmithCurveInfo {
  uint32_t plane;
  int32_t closed;
  int32_t exact;
  double error;
} CadaclysmBlacksmithCurveInfo;

/**
 * A curve's length mass properties, per unit length density (Rhino's `LengthMassProperties`),
 * each figure beside an estimate of its own error.
 *
 * `inertia` is row-major and symmetric, about the centroid, with the products negated
 * (`inertia[1] = -integral (x - gx)(y - gy) ds`), as `cadaclysm_blacksmith_mass_properties`'
 * is. `principal_moments` ascend; `principal_axes` is row-major, unit and right-handed, row
 * `i` the axis of moment `i`; `radii[i]` is the radius of gyration about it,
 * `sqrt(principal_moments[i] / length)`. Where two moments agree within `inertia_error` any
 * orthonormal pair spanning their plane is as right as another. The moments about another
 * point follow by the parallel-axis rule from the centroid's. `accuracy_met` (1 or 0) says
 * every error is within the accuracy asked of its scale; `from_polyline` is 1 for a sampled
 * polyline (exact for its points).
 */
typedef struct CadaclysmBlacksmithLengthMass {
  double length;
  double length_error;
  double centroid[3];
  double centroid_error;
  double inertia[9];
  double inertia_error;
  double principal_moments[3];
  double principal_axes[9];
  double radii[3];
  int32_t accuracy_met;
  int32_t from_polyline;
} CadaclysmBlacksmithLengthMass;

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
 * [`cadaclysm_blacksmith_gpu_edge_normals`]' answer: twelve floats a Bezier, borrowed from
 * the solid's cache.
 */
typedef struct CadaclysmBlacksmithEdgeNormals {
  const float *normals;
  uint32_t count;
} CadaclysmBlacksmithEdgeNormals;

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
   * `POLYLINES` | `SILHOUETTES` | `HIDDEN_REMOVED` | `HIDDEN_DASHED`, with
   * `EDGES | SILHOUETTES` the default.
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
 * A set's rings, flat. Every pointer is borrowed from the set and good until it is freed.
 */
typedef struct CadaclysmBlacksmithPolygonSetView {
  /**
   * 2 doubles a point, ring after ring.
   */
  const double *xy;
  uint32_t point_count;
  /**
   * Points in each ring.
   */
  const uint32_t *ring_sizes;
  uint32_t ring_count;
  /**
   * Rings in each polygon: its outer ring, then its holes.
   */
  const uint32_t *polygon_rings;
  uint32_t polygon_count;
} CadaclysmBlacksmithPolygonSetView;

/**
 * Polylines, flat. Every pointer is borrowed from the handle and good until it is freed.
 */
typedef struct CadaclysmBlacksmithPolygonSetLinesView {
  /**
   * 2 doubles a point, line after line.
   */
  const double *xy;
  uint32_t point_count;
  /**
   * Points in each line.
   */
  const uint32_t *sizes;
  uint32_t count;
} CadaclysmBlacksmithPolygonSetLinesView;

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
 * How a sheet-metal part is made: the sheet's `thickness`, the bends' inner `bend_radius`
 * (0: a hundredth of the thickness) and `k_factor` in [0, 1] (the neutral layer `K T` past
 * the inner face); the bend `relief` (`CADACLYSM_BLACKSMITH_RELIEF_*`) cut where a flange is
 * shorter than its edge, its width (0: `T`) and depth past the zone (0: `T / 2`); the
 * `corner` relief (`CADACLYSM_BLACKSMITH_CORNER_*`) where two bends meet and its size (0:
 * `2 T`); the gap left between two flanges meeting at a corner (0: `T / 10`).
 * [`cadaclysm_blacksmith_sheet_rule_default`] fills one.
 */
typedef struct CadaclysmBlacksmithSheetRule {
  double thickness;
  double bend_radius;
  double k_factor;
  uint32_t relief;
  double relief_width;
  double relief_depth;
  uint32_t corner;
  double corner_size;
  double miter_gap;
} CadaclysmBlacksmithSheetRule;

/**
 * A sheet body as [`cadaclysm_blacksmith_sheet_info`] reads it: its thickness, the flat face
 * it is laid from, and how many bends it has.
 */
typedef struct CadaclysmBlacksmithSheetInfo {
  double thickness;
  uint32_t fixed_face;
  uint32_t bend_count;
} CadaclysmBlacksmithSheetInfo;

/**
 * One bend of a sheet body: its face on the fixed face's side (`a_face`) and its partner
 * (`b_face`), the inner `radius`, the signed `angle` (> 0 when `a_face` is inside: up from
 * the fixed side), the `axis` (a point and a unit direction) and the bend's `line` on the
 * mid-thickness surface (two points).
 */
typedef struct CadaclysmBlacksmithBendInfo {
  uint32_t a_face;
  uint32_t b_face;
  double radius;
  double angle;
  double axis[6];
  double line[6];
} CadaclysmBlacksmithBendInfo;

/**
 * One bend zone of a flat pattern, in the flat's own plane: the `centre` line and the zone's
 * `start` and `end` lines (each x0, y0, x1, y1), the signed `angle`, inner `radius`,
 * `k_factor`, `up` (1 when it bends up, seen from the flat's top), the `allowance` and the
 * `deduction`.
 */
typedef struct CadaclysmBlacksmithFlatBend {
  double centre[4];
  double start[4];
  double end[4];
  double angle;
  double radius;
  double k_factor;
  uint32_t up;
  double allowance;
  double deduction;
} CadaclysmBlacksmithFlatBend;

/**
 * A bend to fold ([`cadaclysm_blacksmith_fold_flat`]): its `line` across the flat (x0, y0,
 * x1, y1), the signed `angle` (> 0 up), inner `radius` and `k_factor`.
 */
typedef struct CadaclysmBlacksmithBend {
  double line[4];
  double angle;
  double radius;
  double k_factor;
} CadaclysmBlacksmithBend;

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
 * `"step.validation_properties"`, `"step.validation_accuracy"`,
 * `"intersect.free_form_exact"`; the error for a wrong value says what each takes;
 * the two tolerance options are explained at
 * [`cadaclysm_blacksmith_effective_tolerance`]; `"intersect.free_form_exact"` (0 or
 * 1, default 0) makes [`cadaclysm_blacksmith_intersect`]'s exact route take
 * free-form faces too, at several times the mesh route's cost where it answers):
 * one call for all of them, so an
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
 * An animation with no tracks. Null (and `last_error`) only if the library panicked making it.
 */
struct CadaclysmBlacksmithAnimation *cadaclysm_blacksmith_animation_new(void);

/**
 * A copy of `animation`, with names of its own: freeing either leaves the other's borrowed names
 * valid. Null (and `last_error`) for null.
 *
 * # Safety
 * `animation` live.
 */
struct CadaclysmBlacksmithAnimation *cadaclysm_blacksmith_animation_clone(const struct CadaclysmBlacksmithAnimation *animation);

/**
 * Adds a track driving `channel` of `target`: `count` keys at `times` (seconds), each with
 * `dimension` doubles of `values` (flat, key `k` at `k * dimension`), read by `mode`. Answers
 * the new track's index; a target named for the first time becomes the next target.
 *
 * -1 and `last_error`, the animation left as it was, for a null animation or target, a target
 * that is empty or not UTF-8, a channel that is not one of the seven, a mode that is not one of
 * the five, a `dimension` other than the channel's (or 0 for a value track), no keys (`count`
 * 0), more than 1 000 000 keys, a null `times` or `values` with keys to read, a time NaN,
 * infinite, negative or not after the one before (by its key), and a value NaN or infinite (by
 * its key).
 *
 * # Safety
 * `animation` live; `target` a NUL-terminated string; `times` readable for `count` doubles and
 * `values` for `count * dimension`.
 */
int32_t cadaclysm_blacksmith_animation_add_track(struct CadaclysmBlacksmithAnimation *animation,
                                                 const char *target,
                                                 uint32_t channel,
                                                 uint32_t mode,
                                                 const double *times,
                                                 const double *values,
                                                 uint32_t count,
                                                 uint32_t dimension);

/**
 * Sets the point rotate or scale track `track` works about (`pivot3`) and a rotate's axis
 * (`axis3`, normalised when read; a scale keeps it but never reads it). Until set, the origin
 * and +Z.
 *
 * `false` and `last_error`, the track left as it was, for a null animation, `pivot3` or
 * `axis3`, a track out of range, a track that is not rotate or scale, an entry NaN or infinite,
 * and a rotate axis shorter than 1e-12.
 *
 * # Safety
 * `animation` live; `pivot3` and `axis3` readable for 3 doubles each.
 */
bool cadaclysm_blacksmith_animation_set_pivot(struct CadaclysmBlacksmithAnimation *animation,
                                              uint32_t track,
                                              const double *pivot3,
                                              const double *axis3);

/**
 * How many tracks. 0 (and `last_error`) for null.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_track_count(const struct CadaclysmBlacksmithAnimation *animation);

/**
 * How many targets (each name once). 0 (and `last_error`) for null.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_target_count(const struct CadaclysmBlacksmithAnimation *animation);

/**
 * The latest key time over every track, in seconds; 0 with no tracks. 0 (and `last_error`) for
 * null.
 *
 * # Safety
 * `animation` live.
 */
double cadaclysm_blacksmith_animation_duration(const struct CadaclysmBlacksmithAnimation *animation);

/**
 * Target `i`'s name. Borrowed: valid until the animation is freed, and must not be freed itself.
 *
 * Null and `last_error` for a null animation and a target out of range.
 *
 * # Safety
 * `animation` live.
 */
const char *cadaclysm_blacksmith_animation_target(const struct CadaclysmBlacksmithAnimation *animation,
                                                  uint32_t i);

/**
 * Track `track`'s target name. Borrowed: valid until the animation is freed, and must not be
 * freed itself.
 *
 * Null and `last_error` for a null animation and a track out of range.
 *
 * # Safety
 * `animation` live.
 */
const char *cadaclysm_blacksmith_animation_track_target(const struct CadaclysmBlacksmithAnimation *animation,
                                                        uint32_t track);

/**
 * Track `track`'s channel, a `CADACLYSM_BLACKSMITH_CHANNEL_*` constant.
 *
 * `UINT32_MAX` (0 is a channel) and `last_error` for a null animation and a track out of range.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_track_channel(const struct CadaclysmBlacksmithAnimation *animation,
                                                      uint32_t track);

/**
 * Track `track`'s mode as given, a `CADACLYSM_BLACKSMITH_INTERPOLATE_*` constant (visible and
 * ghost read as nearest whatever this says).
 *
 * 0 and `last_error` for a null animation and a track out of range.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_track_mode(const struct CadaclysmBlacksmithAnimation *animation,
                                                   uint32_t track);

/**
 * How many keys track `track` has.
 *
 * 0 and `last_error` for a null animation and a track out of range.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_track_count_keys(const struct CadaclysmBlacksmithAnimation *animation,
                                                         uint32_t track);

/**
 * How many doubles a key of track `track` has.
 *
 * 0 and `last_error` for a null animation and a track out of range.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_track_dimension(const struct CadaclysmBlacksmithAnimation *animation,
                                                        uint32_t track);

/**
 * Track `track`'s pivot then axis into `out6` (the origin and +Z unless set; any track has
 * them, only rotate and scale read them).
 *
 * `false` and `last_error`, with `out6` untouched, for a null animation or `out6` and a track
 * out of range.
 *
 * # Safety
 * `animation` live; `out6` writable for 6 doubles.
 */
bool cadaclysm_blacksmith_animation_track_pivot(const struct CadaclysmBlacksmithAnimation *animation,
                                                uint32_t track,
                                                double *out6);

/**
 * Track `track`'s keys as given: `count` times into `times` and `count * dimension` doubles into
 * `values` (key `k` at `k * dimension`).
 *
 * `false` and `last_error`, with both untouched, for a null animation, `times` or `values`, a
 * track out of range, a `times_len` under the key count, and a `values_len` under
 * `count * dimension`.
 *
 * # Safety
 * `animation` live; `times` writable for `times_len` doubles, `values` for `values_len`.
 */
bool cadaclysm_blacksmith_animation_track_keys(const struct CadaclysmBlacksmithAnimation *animation,
                                               uint32_t track,
                                               double *times,
                                               uint32_t times_len,
                                               double *values,
                                               uint32_t values_len);

/**
 * Track `track`'s value at `t` seconds into `out`, `dimension` doubles.
 *
 * `false` and `last_error`, with `out` untouched, for a null animation or `out`, a track out of
 * range, an `out_len` under the track's dimension, and a `t` that is NaN or infinite.
 *
 * # Safety
 * `animation` live; `out` writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_animation_track_value_at(const struct CadaclysmBlacksmithAnimation *animation,
                                                   uint32_t track,
                                                   double t,
                                                   double *out,
                                                   uint32_t out_len);

/**
 * The sum of every track's dimension: how many doubles `_values_at` writes. 0 (and
 * `last_error`) for null.
 *
 * # Safety
 * `animation` live.
 */
uint32_t cadaclysm_blacksmith_animation_values_size(const struct CadaclysmBlacksmithAnimation *animation);

/**
 * Every track's value at `t` seconds into `out`, the tracks in order, flat: `_values_size`
 * doubles (none, and `out` may be null, with no tracks).
 *
 * `false` and `last_error`, with `out` untouched, for a null animation or `out`, an `out_len`
 * under `_values_size`, and a `t` that is NaN or infinite.
 *
 * # Safety
 * `animation` live; `out` writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_animation_values_at(const struct CadaclysmBlacksmithAnimation *animation,
                                              double t,
                                              double *out,
                                              uint32_t out_len);

/**
 * Target `target`'s placement at `t` seconds into `out16`: its scale, rotate and translate
 * tracks composed (`T_n ... T_1 * R_m ... R_1 * S_k ... S_1`, the first-added of each kind
 * applied first), column-major `out16[col * 4 + row]` with the translation in entries 12, 13
 * and 14 -- the layout the View's placement takes. A target with no such track answers the
 * identity.
 *
 * `false` and `last_error`, with `out16` untouched, for a null animation or `out16`, a target
 * out of range, and a `t` that is NaN or infinite.
 *
 * # Safety
 * `animation` live; `out16` writable for 16 doubles.
 */
bool cadaclysm_blacksmith_animation_placement_at(const struct CadaclysmBlacksmithAnimation *animation,
                                                 uint32_t target,
                                                 double t,
                                                 double *out16);

/**
 * Release an animation, and with it every name it lent. Null is a no-op.
 *
 * # Safety
 * `animation` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_animation_free(struct CadaclysmBlacksmithAnimation *animation);

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
 * Every solid's world placement under `assembly`, in
 * [`cadaclysm_blacksmith_assembly_part_path`]'s order: twelve doubles a part (origin, x
 * axis, y axis, z axis, as every frame argument), its placement frames composed from the
 * top down, written to `out[0 .. 12 * part_count]`. `out_len` is how many doubles `out`
 * holds, at least `12 * cadaclysm_blacksmith_assembly_part_count(assembly)`. False (and
 * `last_error`), `out` untouched, for a null `assembly`, a null `out` with a non-zero
 * `out_len`, or an `out_len` too short (the message says how many it needs).
 *
 * # Safety
 * `assembly` live; `out` null or writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_assembly_part_placements(const struct CadaclysmBlacksmithAssembly *assembly,
                                                   double *out,
                                                   size_t out_len);

/**
 * Every solid's world placement under `assembly` posed: what
 * [`cadaclysm_blacksmith_assembly_posed`] then [`cadaclysm_blacksmith_assembly_part_placements`]
 * give, number for number, without building the posed assembly -- the per-frame call of
 * an animation. `joints`, `counts`, `values`, `row_count`, `state` and `ground` as
 * `cadaclysm_blacksmith_assembly_posed`; `out` and `out_len` as
 * `cadaclysm_blacksmith_assembly_part_placements`. False (and `last_error`), `out`
 * untouched, for a null `assembly`, a bad `out` or `out_len`, and every refusal of
 * `cadaclysm_blacksmith_assembly_posed`, in `posed_placements:` words where it says
 * `posed:`.
 *
 * # Safety
 * `assembly` live; `joints`, `counts`, `values`, `state` and `ground` as
 * `cadaclysm_blacksmith_assembly_posed`; `out` null or writable for `out_len` doubles.
 */
bool cadaclysm_blacksmith_assembly_posed_placements(const struct CadaclysmBlacksmithAssembly *assembly,
                                                    const char *const *joints,
                                                    const uint32_t *counts,
                                                    const double *values,
                                                    size_t row_count,
                                                    const char *state,
                                                    const char *ground,
                                                    double *out,
                                                    size_t out_len);

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
 * [`cadaclysm_blacksmith_job_machine_with`], relieving every inside corner the
 * smallest end mill leaves with a dog-bone when `corner_relief` is true: a cut along
 * the corner's bisector until the cutter touches the corner, reported as a `relief`
 * item in place of the corner item (read through the same report calls). `false` is
 * `job_machine_with` exactly. Refusals as `job_machine_with`'s, named
 * `"job_machine_relieved: ..."`.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_job_machine_with`].
 */
struct CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine_relieved(struct CadaclysmBlacksmithJob *j,
                                                                            const struct CadaclysmBlacksmithSolid *part,
                                                                            const struct CadaclysmBlacksmithTool *const *end_mills,
                                                                            size_t end_mill_count,
                                                                            const struct CadaclysmBlacksmithTool *const *drills,
                                                                            size_t drill_count,
                                                                            double stepover,
                                                                            double stepdown,
                                                                            double skin,
                                                                            double peck,
                                                                            bool corner_relief);

/**
 * How many items. `UINT32_MAX` (and `last_error`) for null.
 *
 * # Safety
 * `r` a live report.
 */
uint32_t cadaclysm_blacksmith_report_count(const struct CadaclysmBlacksmithReport *r);

/**
 * Item `i`'s kind: `"corner"`, `"hole"`, `"slope"`, `"undercut"`, `"too_deep"` or
 * `"relief"` (an inside corner cut beyond the part on purpose, see
 * [`cadaclysm_blacksmith_job_machine_relieved`]). Owned by the report and good until
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
 * The radius of the round face `face` belongs to -- a fillet's face that
 * [`cadaclysm_blacksmith_unfillet`](crate::cadaclysm_blacksmith_unfillet) can take back --
 * 0 where it is none: only cylinders, spheres and tori a fillet made are asked. `face`
 * in the solid's own face order. NaN and `last_error` for a null solid or a face past
 * the end.
 *
 * # Safety
 * `solid` live.
 */
double cadaclysm_blacksmith_face_round_radius(const struct CadaclysmBlacksmithSolid *solid,
                                              uint32_t face);

/**
 * The distance of the chamfer face `face` belongs to -- a bevel
 * [`cadaclysm_blacksmith_unchamfer`](crate::cadaclysm_blacksmith_unchamfer) can take back
 * -- 0 where it is none: only the planes and cones a chamfer made are asked. NaN and
 * `last_error` for a null solid or a face past the end.
 *
 * # Safety
 * `solid` live.
 */
double cadaclysm_blacksmith_face_chamfer_distance(const struct CadaclysmBlacksmithSolid *solid,
                                                  uint32_t face);

/**
 * How many Béziers [`cadaclysm_blacksmith_edge_beziers`] writes for `solid` at
 * `tolerance`. 0 and `last_error` for a null solid or a tolerance negative or infinite.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_edge_bezier_count(const struct CadaclysmBlacksmithSolid *solid,
                                                double tolerance);

/**
 * `solid`'s edges as rational cubic Béziers into `out`, sixteen doubles each -- `x y z
 * w` per control point, the point Cartesian and its weight beside it, the record
 * [`cadaclysm_blacksmith_profile_from_beziers`](crate::cadaclysm_blacksmith_profile_from_beziers)
 * reads: what a viewer draws the solid's edges by. Exact where an edge's curve has a
 * Bézier form (a line one Bézier, a circle quarter-turn conics, a spline its own pieces),
 * flattened within `tolerance` where it has none, and an edge known only as a polyline (a
 * join's new edge, a shell's inner skin) drawn as the straight pieces it is. Size `out`
 * from [`cadaclysm_blacksmith_edge_bezier_count`] at the same tolerance. `false` and
 * `last_error` for a null argument or a tolerance negative or infinite.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `out` `16 * edge_bezier_count` writable doubles.
 */
bool cadaclysm_blacksmith_edge_beziers(const struct CadaclysmBlacksmithSolid *solid,
                                       double tolerance,
                                       double *out);

/**
 * How many Béziers [`cadaclysm_blacksmith_isocurve_beziers`] writes for `solid` at
 * `density` and `tolerance`. 0 and `last_error` for a null solid or a tolerance negative
 * or infinite.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_isocurve_bezier_count(const struct CadaclysmBlacksmithSolid *solid,
                                                    uint32_t density,
                                                    double tolerance);

/**
 * `solid`'s isoparametric curves as rational cubic Béziers into `out`, sixteen doubles
 * each as [`cadaclysm_blacksmith_edge_beziers`] writes them: `density` interior lines
 * each way on every curved face, clipped to the face, plus the lines at the ends of the
 * face's parameter span; a flat face draws none. Exact where the surface has a closed
 * form for the line (a cylinder's rings are circles), flattened within `tolerance`
 * elsewhere. Size `out` from [`cadaclysm_blacksmith_isocurve_bezier_count`] with the same
 * arguments. `false` and `last_error` for a null argument or a tolerance negative or
 * infinite.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `out` `16 * isocurve_bezier_count` writable doubles.
 */
bool cadaclysm_blacksmith_isocurve_beziers(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t density,
                                           double tolerance,
                                           double *out);

/**
 * `count` solids meshed at `tolerance` -- each the mesh
 * [`cadaclysm_blacksmith_mesh`](crate::cadaclysm_blacksmith_mesh) hands out -- written to
 * one file in `format`:
 *
 * - `"stl"`: binary STL, every solid's triangles in one body;
 * - `"stl-ascii"`: ASCII STL, one body named as the first solid;
 * - `"obj"`: Wavefront OBJ, one named object a solid, no material library;
 * - `"glb"`, `"gltf"`: glTF 2.0, one named node a solid in a material of its own -- the
 *   binary `.glb`, or the `.gltf` JSON with its buffer embedded;
 * - `"3mf"`: a 3MF package, one named object and build item a solid, in millimetres;
 * - `"ply"`, `"ply-ascii"`: PLY, binary little-endian or ASCII, every solid's triangles in
 *   one body.
 *
 * 3MF and PLY carry the solids' colours: each face its own where it was coloured, else the
 * solid's -- 3MF a colour a triangle, PLY a colour a vertex. A file where no solid is
 * coloured carries none.
 *
 * `names` NULL, or one NUL-terminated name a solid (NULL: each solid's own name, else
 * `Solid 1`, `Solid 2`, ...). `looks` NULL, or six doubles a solid -- linear `r g b a`,
 * then `metallic` and `roughness`, each clamped into 0..1 -- the glTF's materials (NULL:
 * each solid's own colour, else a light grey, not metallic, roughness 0.5); the other
 * formats ignore them.
 *
 * The bytes are owned, their count written through `len`: release them with
 * [`cadaclysm_blacksmith_bytes_free`](crate::cadaclysm_blacksmith_bytes_free). NULL and
 * `last_error` for no solids, a null argument, an unknown format, a name not UTF-8, a look
 * value not finite, or a solid that cannot be meshed.
 *
 * `tolerance` 0 or NaN: each solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solids` `count` live solids; `format` a NUL-terminated string; `names` NULL or `count`
 * NUL-terminated strings; `looks` NULL or `6 * count` doubles; `len` a writable `size_t`.
 */
uint8_t *cadaclysm_blacksmith_mesh_file(const struct CadaclysmBlacksmithSolid *const *solids,
                                        size_t count,
                                        const char *format,
                                        const char *const *names,
                                        const double *looks,
                                        double tolerance,
                                        size_t *len);

/**
 * A rectangular pattern's placements: `count1` instances `spacing1` apart along `direction1`
 * (three doubles, normalised), times `count2` `spacing2` apart along `direction2` -- or one row
 * when `direction2` is NULL (`count2` then 1). Row-major, direction 1 fastest, instance 0 the
 * identity. `symmetric` puts `count` on each side of the original along each direction
 * (`2 count - 1`, at offsets `0, +s, -s, +2s, -2s, ...`). `skip`, `skip_count` indices, leaves
 * instances out (Fusion's suppressed instances), 0 included.
 *
 * Returns the count of placements, writing 16 doubles each to `out`; with `out` NULL it writes
 * nothing, so call it twice: once to size the buffer, once to fill it. A non-null `out` must
 * hold the whole count. 0 (and `last_error`) when refused: a count of 0, a spacing not finite,
 * a zero direction, a skip past the count, every instance skipped, more than 100000 instances.
 *
 * # Safety
 * `direction1` three doubles; `direction2` three or NULL; `skip` `skip_count` indices or NULL
 * with 0; `out` NULL or `16 n` doubles for `n` the count.
 */
uint32_t cadaclysm_blacksmith_pattern_rectangular(const double *direction1,
                                                  uint32_t count1,
                                                  double spacing1,
                                                  const double *direction2,
                                                  uint32_t count2,
                                                  double spacing2,
                                                  bool symmetric,
                                                  const uint32_t *skip,
                                                  uint32_t skip_count,
                                                  double *out);

/**
 * A circular pattern's placements about `axis` (six doubles: a point, a direction): a full
 * turn (`angle` 2 pi) spaces `count` evenly; less than a full turn spreads `count` over
 * `angle` with both ends occupied. `symmetric` spreads `count` over `angle` on each side
 * (`2 count - 1`, at `0, +a, -a, +2a, ...`), refused with a full turn, which has no sides.
 * Angles in radians, right-handed about the direction. `skip` as in
 * [`cadaclysm_blacksmith_pattern_rectangular`].
 *
 * Returns the count, with the two-call convention of
 * [`cadaclysm_blacksmith_pattern_rectangular`]; 0 (and `last_error`) when refused: count 0, a
 * zero axis, an angle not in (0, 2 pi], the skips, more than 100000 instances.
 *
 * # Safety
 * `axis` six doubles; `skip` `skip_count` indices or NULL with 0; `out` NULL or `16 n` doubles.
 */
uint32_t cadaclysm_blacksmith_pattern_circular(const double *axis,
                                               uint32_t count,
                                               double angle,
                                               bool symmetric,
                                               const uint32_t *skip,
                                               uint32_t skip_count,
                                               double *out);

/**
 * A pattern's placements along `curve`: `count` instances by arc length from its start,
 * `spacing` apart -- or, with `spacing` NaN, spread over the curve's whole length with both ends
 * occupied. Each moves the original by its point less the start; `orient`
 * `CADACLYSM_BLACKSMITH_ORIENT_PATH` also turns it by the curve's rotation-minimising frame
 * from the first instance's (`CADACLYSM_BLACKSMITH_ORIENT_FIXED` translates only). `skip` as in
 * [`cadaclysm_blacksmith_pattern_rectangular`].
 *
 * Returns the count, with the two-call convention of
 * [`cadaclysm_blacksmith_pattern_rectangular`]; 0 (and `last_error`) when refused: count 0, a
 * spacing not positive, `count - 1` spacings past the curve's length, a curve of zero length,
 * an unknown `orient`, the skips, more than 100000 instances.
 *
 * # Safety
 * `curve` live; `skip` `skip_count` indices or NULL with 0; `out` NULL or `16 n` doubles.
 */
uint32_t cadaclysm_blacksmith_pattern_along(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                            uint32_t count,
                                            double spacing,
                                            uint32_t orient,
                                            const uint32_t *skip,
                                            uint32_t skip_count,
                                            double *out);

/**
 * A mirror's placements: the identity (the original) and the reflection across `plane` (twelve
 * doubles: origin, x, y, z, as [`cadaclysm_blacksmith_transform_mirror`](crate::cadaclysm_blacksmith_transform_mirror);
 * `z` the normal, the origin any point on the plane). Not rigid: the reflection turns a body
 * inside out, which [`cadaclysm_blacksmith_pattern`] and [`cadaclysm_blacksmith_pattern_feature`]
 * accept.
 *
 * Returns the count (2), with the two-call convention of
 * [`cadaclysm_blacksmith_pattern_rectangular`]; 0 (and `last_error`) when refused: a NULL plane,
 * one not finite, a zero normal.
 *
 * # Safety
 * `plane` twelve doubles; `out` NULL or 32 doubles.
 */
uint32_t cadaclysm_blacksmith_pattern_mirror(const double *plane,
                                             double *out);

/**
 * `solid` and its copies at `count` placements (`transforms`, 16 doubles each, rigid) as one
 * body -- a pattern of bodies. Copies apart from each other are put together with no boolean
 * at all; copies that overlap are joined, one boolean a group. `report_out`, when not NULL,
 * gets three doubles: the instances placed, the booleans run, and 0 (no copy of a body
 * misses). Refused: no transforms, one neither rigid nor a mirror.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `transforms` `16 count` doubles; `report_out` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pattern(const struct CadaclysmBlacksmithSolid *solid,
                                                              const double *transforms,
                                                              uint32_t count,
                                                              double tolerance,
                                                              double *report_out);

/**
 * `tool` (any closed solid, typically a `_tool` call's result) placed at each of `count`
 * placements and applied to `solid` by `op` -- `CADACLYSM_BLACKSMITH_FEATURE_CUT` or
 * `CADACLYSM_BLACKSMITH_FEATURE_JOIN` -- a pattern of features. Copies apart from each other go
 * into one multi-lump tool and one boolean; overlapping copies fall into a few groups. A copy
 * that shares no volume with the body is missed: dropped for a cut, kept as a body of its own
 * for a join. A cut where every copy misses returns the body unchanged, with 0 booleans.
 * `report_out`, when not NULL, gets three doubles: instances, booleans, missed. Refused: no
 * transforms, one neither rigid nor a mirror, a tool that is not closed, an unknown `op`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid`, `tool` live; `transforms` `16 count` doubles; `report_out` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pattern_feature(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const struct CadaclysmBlacksmithSolid *tool,
                                                                      uint32_t op,
                                                                      const double *transforms,
                                                                      uint32_t count,
                                                                      double tolerance,
                                                                      double *report_out);

/**
 * `solid` drilled at each of `count` points (`points`, three doubles each) with one hole, all in
 * one cut. The bore is an exact cylinder of `diameter`; `direction` (three doubles, into the
 * material, shared by every point) or, when NULL, each point's face's inward normal there --
 * each point must then lie on a face (on an edge, the lowest-numbered face's normal).
 *
 * `extent`: `CADACLYSM_BLACKSMITH_HOLE_THROUGH` through everything ahead;
 * `CADACLYSM_BLACKSMITH_HOLE_BLIND` `depth` of full bore from the point, then a drill point of
 * included angle `tip_angle` (0 or pi: a flat bottom); `CADACLYSM_BLACKSMITH_HOLE_TO_FACE`
 * until the axis first meets face `face`, the bore ending on it; `CADACLYSM_BLACKSMITH_HOLE_TO_NEXT`
 * until the bore first leaves the material. `depth` is NaN (or 0) and `face`
 * `CADACLYSM_BLACKSMITH_NONE` unless their extent asks for them.
 *
 * `head`: `CADACLYSM_BLACKSMITH_HOLE_SIMPLE`; `CADACLYSM_BLACKSMITH_HOLE_COUNTERBORE`, a bore
 * `head_diameter` across and `head_depth` deep; `CADACLYSM_BLACKSMITH_HOLE_COUNTERSINK`, a cone
 * `head_diameter` across at the point of included angle `head_angle` -- measured from the
 * point. Angles in radians.
 *
 * `report_out`, when not NULL, gets two doubles: the holes drilled and the faces of the result
 * on no surface of the body. `bottoms_out`, when not NULL, gets `count` doubles: per hole, the
 * distance along the axis from the point to where the bore ends, the drill point excluded.
 * Refused: a diameter not positive; no points or one not finite; a zero direction; a depth
 * given for an extent other than blind, a face for one other than to_face, none for to_face, a
 * face past the end; a head diameter not above the diameter; a counterbore not shallower than a
 * blind depth; an angle out of range; a point not on a face with no direction; a hole that
 * removes nothing; a face the axis never meets.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `points` `3 count` doubles; `direction` three or NULL; `report_out` two doubles
 * or NULL; `bottoms_out` `count` doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole(const struct CadaclysmBlacksmithSolid *solid,
                                                           const double *points,
                                                           uint32_t count,
                                                           double diameter,
                                                           const double *direction,
                                                           uint32_t extent,
                                                           double depth,
                                                           double tip_angle,
                                                           uint32_t face,
                                                           uint32_t head,
                                                           double head_diameter,
                                                           double head_depth,
                                                           double head_angle,
                                                           double tolerance,
                                                           double *report_out,
                                                           double *bottoms_out);

/**
 * The tool [`cadaclysm_blacksmith_hole`] cuts with, from the same arguments: a closed solid,
 * one lump a point, each the hole's half section revolved -- for
 * [`cadaclysm_blacksmith_pattern_feature`] or a boolean of the caller's own. Refused as
 * [`cadaclysm_blacksmith_hole`] is, but for a hole that removes nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_hole`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                                const double *points,
                                                                uint32_t count,
                                                                double diameter,
                                                                const double *direction,
                                                                uint32_t extent,
                                                                double depth,
                                                                double tip_angle,
                                                                uint32_t face,
                                                                uint32_t head,
                                                                double head_diameter,
                                                                double head_depth,
                                                                double head_angle,
                                                                double tolerance);

/**
 * `solid` with a rib along `curve` -- an open curve lying in `plane` (a frame, twelve doubles:
 * origin, x, y, z). The rib fills the region of the plane between the curve and the body on
 * the `toward` side (three doubles, a direction in the plane; NULL: from the curve's midpoint
 * toward the body's nearest point), the curve's ends carried on along their tangents to the
 * body, thickened `thickness` along the plane's normal: `side`
 * `CADACLYSM_BLACKSMITH_RIB_BOTH` half each side, `CADACLYSM_BLACKSMITH_RIB_FRONT` on +z,
 * `CADACLYSM_BLACKSMITH_RIB_BACK` on -z. One join. Refused: the curve closed or not in the
 * plane; a thickness not positive; an unknown `side`; the slab meeting nothing; a region not
 * closed by the body on the `toward` side.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid`, `curve` live; `plane` twelve doubles; `toward` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib(const struct CadaclysmBlacksmithSolid *solid,
                                                          const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                          const double *plane,
                                                          double thickness,
                                                          uint32_t side,
                                                          const double *toward,
                                                          double tolerance);

/**
 * The slab [`cadaclysm_blacksmith_rib`] joins, alone, from the same arguments.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_rib`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                               const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                               const double *plane,
                                                               double thickness,
                                                               uint32_t side,
                                                               const double *toward,
                                                               double tolerance);

/**
 * `solid` with a revolved rib: the region
 * [`cadaclysm_blacksmith_rib`] would fill, drawn in the plane holding `axis` (six doubles: a
 * point and a direction) and `curve` (open, in that plane), clipped to the curve's side of the
 * axis and swung `angle` radians about it, symmetric about the curve's plane. `toward` as
 * [`cadaclysm_blacksmith_rib`]'s. One join. Refused: an angle not in (0, 2 pi); the axis's
 * direction zero; the curve closed or not in one plane with the axis; the slab meeting
 * nothing; a region not closed by the body on the `toward` side.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid`, `curve` live; `axis` six doubles; `toward` three doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib_revolved(const struct CadaclysmBlacksmithSolid *solid,
                                                                   const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                   const double *axis,
                                                                   double angle,
                                                                   const double *toward,
                                                                   double tolerance);

/**
 * The solid [`cadaclysm_blacksmith_rib_revolved`] joins, alone, from the same arguments.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_rib_revolved`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib_revolved_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                        const double *axis,
                                                                        double angle,
                                                                        const double *toward,
                                                                        double tolerance);

/**
 * `solid` with a web along each of `count` `curves` -- open curves lying in `plane` (a frame,
 * twelve doubles). Each is offset in the plane to `thickness`: `side`
 * `CADACLYSM_BLACKSMITH_WEB_BOTH` half each side, `CADACLYSM_BLACKSMITH_WEB_LEFT` or
 * `CADACLYSM_BLACKSMITH_WEB_RIGHT` of the curve's run (the plane's normal up); its ends carried
 * along their tangents to the body; its walls run along the plane's normal until they meet the
 * body (`depth` NaN) or for `depth`, one way (the normal's) or both when `both_ways`. All the
 * webs are one tool and one join; crossing curves make a network. Refused: no curves; one
 * closed or not in the plane; a thickness not positive; an unknown `side`; walls meeting
 * nothing, or not closed by the body.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `curves` `count` live curves; `plane` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_web(const struct CadaclysmBlacksmithSolid *solid,
                                                          const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                          uint32_t count,
                                                          const double *plane,
                                                          double thickness,
                                                          uint32_t side,
                                                          double depth,
                                                          bool both_ways,
                                                          double tolerance);

/**
 * The walls [`cadaclysm_blacksmith_web`] joins, alone, from the same arguments.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_web`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_web_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                               const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                               uint32_t count,
                                                               const double *plane,
                                                               double thickness,
                                                               uint32_t side,
                                                               double depth,
                                                               bool both_ways,
                                                               double tolerance);

/**
 * How many rows the thread size table has: ISO metric coarse M1 .. M64, ISO metric fine
 * M8x1 .. M64x4, UNC #1 .. 1-1/2", UNF #0 .. 1-1/2", in that order, each by ascending major.
 */
uint32_t cadaclysm_blacksmith_thread_size_count(void);

/**
 * Row `index` of the thread size table: its designation (`"M10"`, `"M10x1.25"`, `"1/4-20 UNC"`),
 * static and NUL-terminated, for the library's life -- never freed. `out`, when not NULL, gets
 * nine doubles: the family (`CADACLYSM_BLACKSMITH_THREAD_ISO_METRIC_COARSE` ..
 * `CADACLYSM_BLACKSMITH_THREAD_UNF`), the major diameter, the pitch, the basic minor diameter
 * `D - 1.082532 P`, the pitch diameter `D - 0.649519 P`, the tap drill `D - P` (the ~75 %
 * engagement rule, not a drill chart), and ISO 273's fine, medium and coarse clearance holes (0
 * for a UN row or a size ISO 273 has no row for). Millimetres throughout. NULL (and
 * `last_error`) past the end.
 *
 * # Safety
 * `out` nine doubles or NULL.
 */
const char *cadaclysm_blacksmith_thread_size_at(uint32_t index, double *out);

/**
 * Row `index`'s size (`"M10"`, `"1/4"`, `"#10"`), static as
 * [`cadaclysm_blacksmith_thread_size_at`]'s designation. NULL (and `last_error`) past the end.
 */
const char *cadaclysm_blacksmith_thread_size_size(uint32_t index);

/**
 * The index of the row `designation` names: the exact designation first, then forgiven --
 * case and spaces ignored, `"M10"` the coarse row, `"M10x1.25"` / `"M10 x 1.25"` the fine one,
 * `"1/4-20"` the UNC or UNF row of that TPI. -1 (and `last_error`) when no row matches or
 * `designation` is NULL.
 *
 * # Safety
 * `designation` a NUL-terminated string.
 */
int32_t cadaclysm_blacksmith_thread_size_find(const char *designation);

/**
 * `solid` with a screw thread cut into cylindrical face `face` -- an exact cylinder, or a
 * free-form face recognised as one at the tolerance. The face's normal says the kind: away
 * from the axis an external thread (a rod), toward it an internal one (a bore). The cutter is
 * one coil of a closed section of the basic ISO 68-1 profile at `angle` (the included flank
 * angle, radians; NaN 60 degrees), cut in one boolean.
 *
 * The form: `designation`, a size in the table ([`cadaclysm_blacksmith_thread_size_find`]'s
 * forgiving lookup), with `pitch` and `diameter` NaN; or `designation` NULL, `pitch` > 0 and
 * `diameter` the major (NaN: the face's diameter for an external thread, the face as the basic
 * minor for an internal one). The face must lie in the thread's band -- external `[D2, D +
 * P/8]`, internal `[D1 - P/8, D2]`.
 *
 * The span runs along the axis from the face's open end (air past it: a rod's tip, a bore's
 * mouth) -- or, both or neither open, the end lower along the face cylinder's axis;
 * `CADACLYSM_BLACKSMITH_THREAD_REVERSE` the other -- after `offset`, for `length` (NaN: the
 * rest of the face). Where it ends at an open end the groove runs out through it; elsewhere
 * the coil stops on its own cap, under a pitch short. `CADACLYSM_BLACKSMITH_THREAD_LEFT_HANDED`
 * climbs the other way.
 *
 * `report_out`, when not NULL, gets thirteen doubles: internal (1 or 0), major, minor, pitch,
 * the span's start on the axis (x, y, z), the unit direction into the span (x, y, z), its
 * length, the coil's turns (overshoot included), the faces added. Refused, by name: a NULL
 * solid; a face past the end or not cylindrical; a designation not in the table; a size and a
 * pitch or diameter both given; neither a size nor a pitch; a flag that is not one of the
 * above, or `CADACLYSM_BLACKSMITH_THREAD_COSMETIC` (the tapped hole's); a pitch, diameter or
 * length not positive; an offset negative; an angle out of (0, pi) or making the section as
 * wide as the pitch; the face outside the band; the span past the face; a cut that removes
 * nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `designation` a NUL-terminated string or NULL; `report_out` thirteen doubles or
 * NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_thread(const struct CadaclysmBlacksmithSolid *solid,
                                                             uint32_t face,
                                                             const char *designation,
                                                             double pitch,
                                                             double diameter,
                                                             double angle,
                                                             double length,
                                                             double offset,
                                                             uint32_t flags,
                                                             double tolerance,
                                                             double *report_out);

/**
 * The cutter [`cadaclysm_blacksmith_thread`] cuts with, from the same arguments: one closed
 * coil, for a boolean of the caller's own. Refused as [`cadaclysm_blacksmith_thread`] is, but
 * for a cut that removes nothing.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `designation` a NUL-terminated string or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_thread_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                                  uint32_t face,
                                                                  const char *designation,
                                                                  double pitch,
                                                                  double diameter,
                                                                  double angle,
                                                                  double length,
                                                                  double offset,
                                                                  uint32_t flags,
                                                                  double tolerance);

/**
 * `solid` unchanged but for a cosmetic thread on face `face`: the thread validated as
 * [`cadaclysm_blacksmith_thread`] validates it (a cylindrical face, the band, the span; the
 * angle 60 degrees), its figures written as the face's attributes `thread.designation` (the
 * row's, `""` for an explicit form), `thread.major`, `thread.pitch`, `thread.length`,
 * `thread.offset` (shortest round-trip decimal text), `thread.internal`, `thread.left_handed`,
 * `thread.reverse` (`"1"` or `"0"`). Verbs carry face attributes to the faces of their results;
 * [`cadaclysm_blacksmith_thread_record`] reads them back. Refused as
 * [`cadaclysm_blacksmith_thread`] is, `CADACLYSM_BLACKSMITH_THREAD_COSMETIC` included.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `designation` a NUL-terminated string or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cosmetic_thread(const struct CadaclysmBlacksmithSolid *solid,
                                                                      uint32_t face,
                                                                      const char *designation,
                                                                      double pitch,
                                                                      double diameter,
                                                                      double length,
                                                                      double offset,
                                                                      uint32_t flags,
                                                                      double tolerance);

/**
 * Whether face `face` carries a complete cosmetic thread record (every key of
 * [`cadaclysm_blacksmith_cosmetic_thread`] present and parsable); false, with no `last_error`,
 * when it does not. When it does, `out` (when not NULL) gets seven doubles -- major, pitch,
 * length, offset, internal, left_handed, reverse (the last three 1 or 0) -- and
 * `designation_out` (when not NULL) the designation, `""` for an explicit form: borrowed, it
 * lives as long as `solid` and must not be freed. False and `last_error` for a face the solid
 * does not have or a NULL solid.
 *
 * # Safety
 * `solid` live; `out` seven doubles or NULL; `designation_out` NULL or a place for one pointer.
 */
bool cadaclysm_blacksmith_thread_record(const struct CadaclysmBlacksmithSolid *solid,
                                        uint32_t face,
                                        double *out,
                                        const char **designation_out);

/**
 * [`cadaclysm_blacksmith_hole`] tapped: its arguments up to `tolerance`, then the thread --
 * `designation` a size in the table, `thread_depth` its length from where it starts (NaN: the
 * bore's whole length), `flags` `CADACLYSM_BLACKSMITH_THREAD_LEFT_HANDED` and
 * `CADACLYSM_BLACKSMITH_THREAD_COSMETIC`. A `diameter` of 0 is the tap drill `major - pitch`; a
 * given one must lie in the internal band `[D1 - P/8, D2]`; a head must be wider than the
 * major. The thread starts at the point (a counterbore's floor). Modelled, every hole's thread
 * coil is cut in one more boolean after the holes; with `CADACLYSM_BLACKSMITH_THREAD_COSMETIC`
 * the bore alone, each hole's bore face carrying a cosmetic thread record
 * ([`cadaclysm_blacksmith_thread_record`]).
 *
 * `report_out` and `bottoms_out` as [`cadaclysm_blacksmith_hole`]'s; `thread_depths_out`, when
 * not NULL, gets `count` doubles: per hole, the thread's length. Refused as
 * [`cadaclysm_blacksmith_hole`] is, and: a NULL designation or one not in the table; an
 * unknown flag, or `CADACLYSM_BLACKSMITH_THREAD_REVERSE` (a tapped hole starts at its point);
 * a thread depth not positive or past the bore.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_hole`]; `designation` a NUL-terminated string; `thread_depths_out`
 * `count` doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole_threaded(const struct CadaclysmBlacksmithSolid *solid,
                                                                    const double *points,
                                                                    uint32_t count,
                                                                    double diameter,
                                                                    const double *direction,
                                                                    uint32_t extent,
                                                                    double depth,
                                                                    double tip_angle,
                                                                    uint32_t face,
                                                                    uint32_t head,
                                                                    double head_diameter,
                                                                    double head_depth,
                                                                    double head_angle,
                                                                    const char *designation,
                                                                    double thread_depth,
                                                                    uint32_t flags,
                                                                    double tolerance,
                                                                    double *report_out,
                                                                    double *bottoms_out,
                                                                    double *thread_depths_out);

/**
 * The tool [`cadaclysm_blacksmith_hole_threaded`] cuts with, from the same arguments: the
 * holes' lumps, a modelled thread's coils joined into them (one more boolean, the tool's
 * alone); with `CADACLYSM_BLACKSMITH_THREAD_COSMETIC` the bores alone.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * As [`cadaclysm_blacksmith_hole_threaded`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole_threaded_tool(const struct CadaclysmBlacksmithSolid *solid,
                                                                         const double *points,
                                                                         uint32_t count,
                                                                         double diameter,
                                                                         const double *direction,
                                                                         uint32_t extent,
                                                                         double depth,
                                                                         double tip_angle,
                                                                         uint32_t face,
                                                                         uint32_t head,
                                                                         double head_diameter,
                                                                         double head_depth,
                                                                         double head_angle,
                                                                         const char *designation,
                                                                         double thread_depth,
                                                                         uint32_t flags,
                                                                         double tolerance);

/**
 * The mesh of `positions` (`vertex_count` vertices, 3 doubles each) and `indices`
 * (`triangle_count` triangles, 3 vertex indices each) made a B-rep solid. Points within
 * `weld_tolerance` are welded into one vertex and degenerate triangles dropped; the
 * triangles are then oriented consistently with their neighbours, and each closed component
 * turned outward (a component inside another inward, as a void).
 *
 * * `mode` `CADACLYSM_BLACKSMITH_FROM_MESH_MODE_FACETED` (level 1): one planar face per
 *   triangle, one edge per unique triangle edge.
 * * `CADACLYSM_BLACKSMITH_FROM_MESH_MODE_PLANES` (level 2, merged planes): coplanar
 *   neighbouring triangles -- each normal within `angle_tolerance` (radians) of its region's,
 *   each vertex within `distance_tolerance` of its plane -- become one planar face bounded by
 *   their outline (inner loops for holes), and collinear outline points are dropped, so a
 *   straight run is one line edge: a CAD box's mesh comes back as 6 faces and 12 edges.
 *   Curved regions stay faceted.
 * * `CADACLYSM_BLACKSMITH_FROM_MESH_MODE_PRISMATIC` (level 3): planes merged as level 2, and
 *   curved regions fitted with cylinders, cones, spheres and tori; what fits nothing stays
 *   faceted. Never worse than level 2: where its body is not closed while the mesh was,
 *   holds the mesh's volume less well, or has more faces, level 2's comes back.
 *
 * A tolerance of 0 or NaN is its default: `weld_tolerance` 1e-6 x the bounding-box diagonal,
 * `angle_tolerance` 1 degree, `distance_tolerance` 1e-5 x the diagonal. A `weld_tolerance`
 * given is what the solid declares as its absolute tolerance.
 *
 * The result is a closed solid only where the mesh is watertight, manifold and orientable;
 * otherwise it is an open shell (a sheet), and the report's hole, boundary-edge and
 * non-manifold-edge counts say why. `report`, unless null, receives
 * `CADACLYSM_BLACKSMITH_FROM_MESH_REPORT_LEN` numbers: closed (1 or 0), faces, edges,
 * vertices, holes (boundary loops), boundary edges (one triangle), non-manifold edges (three
 * or more triangles; reported, never repaired), flipped (every triangle whose final winding
 * differs from the input, including whole shells turned outward, or inward as voids) and
 * dropped (degenerate triangles after welding), then the faces by surface: planes (merged
 * plane faces of more than one triangle), cylinders, cones, spheres, tori.
 *
 * Null (and `last_error`, prefixed `from_mesh: `) for a null array behind a non-zero count,
 * no triangles, an index past the vertex count, a coordinate that is not finite, a negative
 * tolerance, every triangle degenerate, or a `mode` that is none of the three codes;
 * `report` is then untouched.
 *
 * # Safety
 * `positions` null or `3 * vertex_count` doubles; `indices` null or `3 * triangle_count`
 * `uint32_t`s; `report` null or `CADACLYSM_BLACKSMITH_FROM_MESH_REPORT_LEN` `uint32_t`s.
 * Free the result with `cadaclysm_blacksmith_solid_free`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_from_mesh(const double *positions,
                                                                uint32_t vertex_count,
                                                                const uint32_t *indices,
                                                                uint32_t triangle_count,
                                                                double weld_tolerance,
                                                                double angle_tolerance,
                                                                double distance_tolerance,
                                                                uint32_t mode,
                                                                uint32_t *report);

/**
 * An involute spur gear of `teeth` teeth of `module`, tooth 0 centred on +X: its flanks
 * NURBS within `tolerance` of the involute, its tips, fillets and root arcs exact. NaN
 * defaults: `pressure_angle` 20 degrees, `shift` 0, `addendum` 1 and `dedendum` 1.25 (factors
 * of the module), `root_fillet` `0.38 module`, `backlash` 0 (taken off this gear's tooth),
 * `tolerance` `1e-4 module`. The report goes to `report_out` (null: not wanted). Null (and
 * `last_error`), the report untouched, for fewer than 4 or more than 10 000 teeth, a module
 * not positive, a pressure angle outside (0, pi/4), a pointed tooth, or a root fillet that
 * does not fit.
 *
 * # Safety
 * `report_out` null or one `CadaclysmBlacksmithGearReport`.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_gear_involute(double module,
                                                                              uint32_t teeth,
                                                                              double pressure_angle,
                                                                              double shift,
                                                                              double addendum,
                                                                              double dedendum,
                                                                              double root_fillet,
                                                                              double backlash,
                                                                              double tolerance,
                                                                              struct CadaclysmBlacksmithGearReport *report_out);

/**
 * A cycloidal clock wheel of `teeth` teeth of `module` driving a pinion of `pinion_leaves`,
 * tooth 0 centred on +X: epicycloidal addendum flanks within `tolerance`, radial dedendum
 * flanks. NaN defaults: `thickness` `pi module / 2`, `addendum` up to the flanks' crossing
 * with the point rounded, `dedendum` 1.57 (a factor of the module), `root_fillet`
 * `0.25 module`, `tolerance` `1e-4 module`. The report goes to `report_out` (null: not
 * wanted). Null (and `last_error`), the report untouched, for a pinion under 6 leaves, a
 * wheel no larger than its pinion, more than 10 000 teeth, a size not positive, or a fillet
 * that does not fit.
 *
 * # Safety
 * `report_out` null or one `CadaclysmBlacksmithGearReport`.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_gear_wheel_cycloidal(double module,
                                                                                     uint32_t teeth,
                                                                                     uint32_t pinion_leaves,
                                                                                     double thickness,
                                                                                     double addendum,
                                                                                     double dedendum,
                                                                                     double root_fillet,
                                                                                     double tolerance,
                                                                                     struct CadaclysmBlacksmithGearReport *report_out);

/**
 * A cycloidal clock pinion of `leaves` leaves of `module` driven by a wheel of `wheel_teeth`,
 * leaf 0 centred on +X: radial flanks inside the pitch circle, `tip`
 * `CADACLYSM_BLACKSMITH_GEAR_TIP_ROUND` or `CADACLYSM_BLACKSMITH_GEAR_TIP_OGIVE`. NaN
 * defaults: `thickness` `1.05 module` (6 to 10 leaves) or `1.25 module`, `clearance`
 * `0.4 module`, `root_fillet` `0.25 module`, `tolerance` `1e-4 module`. The report goes to
 * `report_out` (null: not wanted). Null (and `last_error`), the report untouched, for under 6
 * or over 10 000 leaves, a wheel no larger than the pinion, another `tip`, a size not
 * positive, a negative clearance, or a fillet that does not fit.
 *
 * # Safety
 * `report_out` null or one `CadaclysmBlacksmithGearReport`.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_gear_pinion_cycloidal(double module,
                                                                                      uint32_t leaves,
                                                                                      uint32_t wheel_teeth,
                                                                                      double thickness,
                                                                                      uint32_t tip,
                                                                                      double clearance,
                                                                                      double root_fillet,
                                                                                      double tolerance,
                                                                                      struct CadaclysmBlacksmithGearReport *report_out);

/**
 * The centre distance of two involute gears of `module`, `teeth_first` and `teeth_second`
 * teeth, in mesh without backlash: `m (z1 + z2) / 2 cos(alpha) / cos(alpha_w)`. NaN defaults:
 * shifts 0, `pressure_angle` 20 degrees. NaN (and `last_error`) for a module not positive,
 * fewer than 4 teeth, a pressure angle outside (0, pi/4), or shifts that leave no working
 * pressure angle.
 */
double cadaclysm_blacksmith_gear_centre_distance_involute(double module,
                                                          uint32_t teeth_first,
                                                          uint32_t teeth_second,
                                                          double shift_first,
                                                          double shift_second,
                                                          double pressure_angle);

/**
 * The five numbers of a 4- or 5-digit NACA code ("0012", "2412", "23012", "23112") into `out`:
 * series (4 or 5), camber or design lift, position, thickness, reflex (0 or 1). `m = M/100`,
 * `p = P/10`, `t = TT/100` for MPTT; `cl = 0.15 L`, `p = P/20`, reflex `Q`, `t = TT/100` for
 * LPQTT. False (and `last_error`), `out` untouched, for a code that is not 4 or 5 digits, a
 * 5-digit position outside 1 to 5, a third digit not 0 or 1, reflex at P = 1, a thickness
 * outside (0, 40 %], or camber with no position.
 *
 * # Safety
 * `code` a NUL-terminated string; `out` five doubles.
 */
bool cadaclysm_blacksmith_naca_parse(const char *code, double *out);

/**
 * `count` exact points of `airfoil` (five doubles: series, camber or lift, position, thickness,
 * reflex) at `chord`, cosine-spaced on each surface (`x = (1 - cos(pi i/n))/2`), from the upper trailing edge to the leading edge --
 * the middle point, `(0, 0)` -- and on to the lower trailing edge. `closed_te` closes the
 * trailing edge (`k4` 0.1036): the first and last points are the same `(chord, 0)`; open, they
 * are `0.021 t chord` apart.
 *
 * Returns the count, with the two-call convention: `out` NULL counts, then `2 count` doubles
 * are written. 0 (and `last_error`) when refused: a chord not positive, a count even or outside
 * 7 to 100 000, a series not 4 or 5, a thickness outside (0, 0.4], a camber outside [0, 0.1), a
 * position outside (0, 1) with camber, a 5-digit position not 0.05 to 0.25 by 0.05.
 *
 * # Safety
 * `airfoil` five doubles; `out` NULL or `2 count` doubles.
 */
uint32_t cadaclysm_blacksmith_naca_points(const double *airfoil,
                                          double chord,
                                          uint32_t count,
                                          bool closed_te,
                                          double *out);

/**
 * `controls` (8 to 200) control points of an open clamped cubic on uniform knots -- the spline
 * a page editor without knots of its own draws -- from the upper trailing edge round to the
 * lower, least-squares fitted to cosine-spaced exact points with its ends on the trailing edge.
 * `error_out` (NULL: not wanted) gets the largest distance from 2 001 exact points to the curve.
 *
 * Returns the count, with the two-call convention: `out` NULL counts, then `2 controls` doubles
 * are written. 0 (and `last_error`), `error_out` untouched, when refused: a chord not positive,
 * `controls` outside 8 to 200, or an airfoil [`cadaclysm_blacksmith_naca_points`] refuses.
 *
 * # Safety
 * `airfoil` five doubles; `out` NULL or `2 controls` doubles; `error_out` NULL or one double.
 */
uint32_t cadaclysm_blacksmith_naca_spline(const double *airfoil,
                                          double chord,
                                          uint32_t controls,
                                          bool closed_te,
                                          double *out,
                                          double *error_out);

/**
 * `airfoil` at `chord` as a closed profile: one cubic NURBS within `tolerance` (NaN:
 * `1e-5 chord`) of the exact airfoil, from the upper trailing edge round to the lower, and a
 * line closing an open trailing edge. `error_out` (NULL: not wanted) gets the largest distance
 * found between the NURBS and the airfoil.
 *
 * Null (and `last_error`), `error_out` untouched, when refused: a chord or tolerance not
 * positive, an airfoil [`cadaclysm_blacksmith_naca_points`] refuses, or a fit that misses the
 * tolerance (the message says by how much).
 *
 * # Safety
 * `airfoil` five doubles; `error_out` NULL or one double.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_naca(const double *airfoil,
                                                                     double chord,
                                                                     bool closed_te,
                                                                     double tolerance,
                                                                     double *error_out);

/**
 * Where the follower comes to rest. `driver` (drawn in its own frame, the frame's origin at
 * `driver_pivot_x`, `driver_pivot_y`) is held at `driver_angle`; `follower` (likewise about
 * `follower_pivot_x`, `follower_pivot_y`) starts at `previous` and is urged along `direction`
 * (+1 counter-clockwise, -1 clockwise). A local point `p` of a link at angle `a` lies at
 * `pivot + R(a) p`. Both profiles are regions with their holes. A follower that starts
 * penetrating recoils against `direction` to first contact; otherwise it advances to first
 * contact or to `limit`, an absolute follower angle. The answer never penetrates: in contact
 * the gap is within `tolerance`. Lines and arcs are exact; other segments go through their
 * NURBS form. NaN defaults: `limit` one full turn from `previous` along `direction`,
 * `tolerance` `1e-9` times the larger bounding-box diagonal of the two placed profiles.
 * False (and `last_error`), `out` untouched, for a null profile or `out`, a profile with no
 * segments, a pivot, angle or `previous` not finite, a `direction` other than +1 or -1, a
 * `limit` infinite or not strictly along `direction` from `previous`, a negative or infinite
 * tolerance, a follower that cannot clear by turning, or no convergence within 100 000 gap
 * evaluations.
 *
 * # Safety
 * `driver` and `follower` null or live; `out` null or one `CadaclysmBlacksmithSettle`.
 */
bool cadaclysm_blacksmith_contact_settle(const struct CadaclysmBlacksmithProfile *driver,
                                         double driver_pivot_x,
                                         double driver_pivot_y,
                                         double driver_angle,
                                         const struct CadaclysmBlacksmithProfile *follower,
                                         double follower_pivot_x,
                                         double follower_pivot_y,
                                         double previous,
                                         int32_t direction,
                                         double limit,
                                         double tolerance,
                                         struct CadaclysmBlacksmithSettle *out);

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
 * `{"added": [ids], "changed": [ids], "removed": [ids], "params": [names], "variants": bool,
 * "components": [names], "meta": [apps]}`: owned, release it with [`cadaclysm_blacksmith_string_free`]. Null
 * and `last_error` (the reason) when the op is refused; the document is unchanged.
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
 * [`cadaclysm_blacksmith_document_evaluate`], every kernel call's progress heard by
 * `progress` with the id of the node it is for: a progress bar, or a note of which node
 * was being built when the host died (a crash quarantine). The same statuses as the plain evaluate,
 * owned; the callback only listens, so what is evaluated is the same without it. A
 * cheap-only pass reports nothing.
 *
 * # Safety
 * `doc` a live document; `progress` null or a valid callback.
 */
char *cadaclysm_blacksmith_document_evaluate_with(struct CadaclysmBlacksmithDocument *doc,
                                                  bool cheap_only,
                                                  CadaclysmBlacksmithDocumentProgress progress,
                                                  void *user);

/**
 * What node `id` evaluated to: `"solid"`, `"sheet"`, `"profile"`, `"profiles"` (a profile list,
 * or a sketch's outlines), `"nurbs"`, `"subd"`, `"curve"`, `"list"` (a list holding geometry, as a
 * laced node gives: its items are `id#0`, `id#1`, ..., read by every result call, and
 * [`cadaclysm_blacksmith_document_value`] counts them), `"value"` (a number, text, point, record
 * and the like: read it with [`cadaclysm_blacksmith_document_value`]), `"placements"` (a
 * placements node's instances: [`cadaclysm_blacksmith_document_value`] reads them as
 * `{"type":"placements","count":n,"transforms":[[16 row-major numbers],...]}`), or `"none"` (no
 * such node, or not evaluated yet or failed). Owned.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_result_kind(const struct CadaclysmBlacksmithDocument *doc,
                                                const char *id);

/**
 * Node `id`'s solid or sheet as a new handle: free it with [`cadaclysm_blacksmith_solid_free`].
 * Null and `last_error` when `id` is not an evaluated solid or sheet. `id#i` reads item `i` of a
 * node whose value is a list (a laced node), `id#i#j` an item of that.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_document_result_solid(const struct CadaclysmBlacksmithDocument *doc,
                                                                            const char *id);

/**
 * Node `id`'s garment as a new handle, a copy you can keep editing: free it with
 * [`cadaclysm_blacksmith_garment_free`]. Lengths are in the document's units (millimetres for a
 * millimetre document), so convert a garment from a non-millimetre document to millimetres before
 * `cadaclysm_blacksmith_garment_to_aama`, which writes metric. Null and `last_error` when `id` is not an evaluated garment. `id#i` reads
 * item `i` of a node whose value is a list.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithGarment *cadaclysm_blacksmith_document_result_garment(const struct CadaclysmBlacksmithDocument *doc,
                                                                                const char *id);

/**
 * Node `id`'s profile as a new handle: free it with [`cadaclysm_blacksmith_profile_free`].
 * `id#i` reads item `i` of a node whose value is a list (a laced node), `id#i#j` an item of that.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile(const struct CadaclysmBlacksmithDocument *doc,
                                                                                const char *id);

/**
 * How many profiles node `id` holds, when it is a profile list (or a sketch). `UINT32_MAX` and
 * `last_error` otherwise. `id#i` reads item `i` of a node whose value is a list (a laced node), `id#i#j` an item of that.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
uint32_t cadaclysm_blacksmith_document_result_profile_count(const struct CadaclysmBlacksmithDocument *doc,
                                                            const char *id);

/**
 * Profile `i` of node `id`'s list, as a new handle: free it with
 * [`cadaclysm_blacksmith_profile_free`]. Null and `last_error` past the end. `id#i` reads item `i` of a node whose value is a list (a laced node), `id#i#j` an item of that.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile_at(const struct CadaclysmBlacksmithDocument *doc,
                                                                                   const char *id,
                                                                                   uint32_t i);

/**
 * Node `id`'s NURBS curve as a new handle: free it with [`cadaclysm_blacksmith_nurbs_curve_free`].
 * `id#i` reads item `i` of a node whose value is a list (a laced node), `id#i#j` an item of that.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_document_result_nurbs_curve(const struct CadaclysmBlacksmithDocument *doc,
                                                                                       const char *id);

/**
 * Node `id`'s subdivision cage as a new handle: free it with [`cadaclysm_blacksmith_subd_free`].
 * `id#i` reads item `i` of a node whose value is a list (a laced node), `id#i#j` an item of that.
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
 * A counter that moves once with every change to the document's state: an apply, undo or redo, a
 * branch made, switched to or deleted, a preview frame or its end, a batch's end or abort. Never
 * with an evaluation, a save or a read. A new or loaded document starts at 1; 0 is a null
 * document. A page keys what it read on it.
 *
 * # Safety
 * `doc` null or a live document.
 */
uint64_t cadaclysm_blacksmith_document_revision(const struct CadaclysmBlacksmithDocument *doc);

/**
 * The history started again from the document as it is: one root commit holding it, so undo has
 * nothing to take back and redo nothing to put back, every branch but `main` gone, the head
 * `c0`. The nodes, results and caches are untouched; the revision moves. A file saved after it
 * is format version 3. `false` and `last_error` while a batch, a preview or a probe is open.
 *
 * # Safety
 * `doc` a live document.
 */
bool cadaclysm_blacksmith_document_clear_history(struct CadaclysmBlacksmithDocument *doc);

/**
 * The commit the document is at, by id: `c0` for a new document or a cleared history. Owned.
 * Null and `last_error` for a null document.
 *
 * # Safety
 * `doc` null or a live document.
 */
char *cadaclysm_blacksmith_document_head(const struct CadaclysmBlacksmithDocument *doc);

/**
 * The nodes as [`cadaclysm_blacksmith_document_save`] writes them, as a JSON list: all of them in
 * document order (`ids` null or empty), or the nodes a JSON list of ids names, in that order. The
 * live state: an open batch's or preview's applies are in it. Owned. Null and `last_error` for an
 * unknown id, naming it.
 *
 * # Safety
 * `doc` a live document; `ids` null or a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_nodes(const struct CadaclysmBlacksmithDocument *doc,
                                          const char *ids);

/**
 * The nodes node `id` reads, as a JSON list of ids in document order: those its fields name (frame
 * fields included), or with `transitive` everything those read too, however far, each once.
 * Parameters are walked through, not listed. Owned. Null and `last_error` for an unknown id.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_inputs(const struct CadaclysmBlacksmithDocument *doc,
                                           const char *id,
                                           bool transitive);

/**
 * The mirror of [`cadaclysm_blacksmith_document_inputs`]: the nodes that read node `id`, directly
 * or, with `transitive`, however far (what deleting it would break). Owned. Null and
 * `last_error` for an unknown id.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_readers(const struct CadaclysmBlacksmithDocument *doc,
                                            const char *id,
                                            bool transitive);

/**
 * Tries `op` (JSON, as [`cadaclysm_blacksmith_document_apply`] takes) on a scratch copy of the
 * document and evaluates only the nodes `ids` (a JSON list) names and what they read, however
 * far. The statuses as [`cadaclysm_blacksmith_document_evaluate`] gives them: owned. Until
 * [`cadaclysm_blacksmith_document_probe_end`], those nodes' results (`document_result_*`,
 * `document_value`) are the probe's; every other node's stay the document's. The document's state,
 * cache, history and revision are untouched. Null and `last_error` while a batch, a preview or
 * another probe is open, for an op the scratch copy refuses, or an unknown id. While a probe is
 * open, every call that changes the document is refused.
 *
 * # Safety
 * `doc` a live document; `op` and `ids` NUL-terminated UTF-8 strings.
 */
char *cadaclysm_blacksmith_document_probe(struct CadaclysmBlacksmithDocument *doc,
                                          const char *op,
                                          const char *ids);

/**
 * Ends an open probe: every result is the document's again. No probe open, or a null document,
 * is a no-op.
 *
 * # Safety
 * `doc` null or a live document.
 */
void cadaclysm_blacksmith_document_probe_end(struct CadaclysmBlacksmithDocument *doc);

/**
 * How many Béziers [`cadaclysm_blacksmith_document_result_beziers`] writes for node `id`. 0 and
 * `last_error` when `id` has no curve or profiles (a solid, a value, no result).
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
uint32_t cadaclysm_blacksmith_document_result_bezier_count(const struct CadaclysmBlacksmithDocument *doc,
                                                           const char *id);

/**
 * Node `id`'s sketch curve or profiles as rational cubic Béziers into `out`, sixteen doubles each
 * (`x y z w` per control point, the point Cartesian, its weight beside it). A sketch curve is
 * carried onto its own frame (the world), or onto `frame`; a profile, a profile list or a sketch
 * gives every loop, outline then holes, on the sketch plane (z = 0), or on `frame`. `frame` null,
 * or twelve doubles: origin, x, y, z (x normalised, y squared against it, z not read). An open
 * probe's value is read for a node it evaluated. Size `out` from
 * [`cadaclysm_blacksmith_document_result_bezier_count`]. `false` and `last_error` when `id` has
 * none, or for a frame whose directions are parallel, zero or not finite.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string; `frame` null or twelve doubles;
 * `out` `16 * bezier_count` doubles.
 */
bool cadaclysm_blacksmith_document_result_beziers(const struct CadaclysmBlacksmithDocument *doc,
                                                  const char *id,
                                                  const double *frame,
                                                  double *out);

/**
 * App `app`'s own data about the document as JSON text: what the last `{"op": "meta", "app": ...,
 * "value": ...}` set (undone and saved with the rest, never read by evaluation). Owned. Null when
 * the app keeps none, with `last_error` empty: that is no failure. Null and `last_error` for a
 * null argument.
 *
 * # Safety
 * `doc` a live document; `app` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_document_meta(const struct CadaclysmBlacksmithDocument *doc,
                                         const char *app);

/**
 * Release a document. Null is a no-op.
 *
 * # Safety
 * `doc` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_document_free(struct CadaclysmBlacksmithDocument *doc);

/**
 * `solid` with the `count` faces at `faces` drafted to `angle` (radians) against the pull
 * direction `plane`'s z, about the neutral plane through `plane`'s origin square to it
 * (`plane` a frame, twelve doubles, as `cadaclysm_blacksmith_split_by_plane` takes): each
 * face's new draft angle, absolute, in (-pi/2, pi/2). A plane turns about the line where it
 * crosses the neutral plane, which stays fixed; a cylinder along the pull becomes the cone
 * through the circle it cuts in the neutral plane (a cone along the pull the same from its
 * own circle there), narrowing towards `+z` for an outer wall drafted positive and widening
 * for a hole. The faces beside a drafted one follow it: every vertex moves onto the drafted
 * faces and the planes it lay on, a vertex in the neutral plane not at all. The faces keep
 * their order, their colours and their marks.
 *
 * Null and `last_error` (starting `draft: `) for no faces, a face the solid does not have or
 * named twice, an angle not finite or not inside (-pi/2, pi/2), a neutral plane with no
 * direction, a solid a reader made whose faces cannot be built again, a face parallel to the
 * neutral plane, a cylinder or cone across the pull, a sphere, torus or free-form face, a
 * curved face beside a drafted one that is not drafted with it, a hole through a drafted
 * plane, a drafted plane and a drafted cylinder meeting at a sharp edge, a face that turns
 * inside out or collapses at the angle asked, and a result that does not close.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 * `progress` is accepted for the shape of the other verbs; a draft reports nothing yet.
 *
 * # Safety
 * `solid` live; `faces` `count` indices; `plane` twelve doubles; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_draft(const struct CadaclysmBlacksmithSolid *solid,
                                                            const uint32_t *faces,
                                                            size_t count,
                                                            const double *plane,
                                                            double angle,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

/**
 * `solid` with the `count` faces at `faces` drafted both ways from the neutral plane through
 * `plane`'s origin square to its z (a frame, twelve doubles) -- a parting line: above it
 * (along `+z`) to `above` against `+z`, below it to `below` against `-z`, so for positive
 * angles both halves narrow away from the plane. `above == below` is a symmetric draft. A face
 * wholly on one side is drafted as [`cadaclysm_blacksmith_draft`] drafts it; otherwise the
 * solid is split by the plane, each side drafted and the halves joined back, the faces the
 * plane cut in two made one again. The faces come back in the join's order; each keeps its
 * colour and marks, a drafted half its face's.
 *
 * Null and `last_error` (starting `draft: `) for what [`cadaclysm_blacksmith_draft`] refuses,
 * and a split that gives no piece on one side of the plane.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `faces` `count` indices; `plane` twelve doubles; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_draft_two_sided(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const uint32_t *faces,
                                                                      size_t count,
                                                                      const double *plane,
                                                                      double above,
                                                                      double below,
                                                                      double tolerance,
                                                                      CadaclysmBlacksmithProgress progress,
                                                                      void *user);

/**
 * The point of face `face` of `solid` nearest `point` (3 doubles) and the draft angle there
 * against `pull` (3 doubles, normalised here), into `out` -- Rhino's `DraftAnglePoint`. A point
 * on the face's boundary reads the face's own normal there, not the mean of the faces meeting.
 * `false` and `last_error` (starting `draft_angle_at: `), `out` untouched, for a null solid,
 * point, pull or `out`, a face out of range, a point not finite, or a pull zero or not finite.
 *
 * # Safety
 * `solid` live; `point` and `pull` 3 doubles each; `out` one `CadaclysmBlacksmithDraftPoint`.
 */
bool cadaclysm_blacksmith_draft_angle_at(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t face,
                                         const double *point,
                                         const double *pull,
                                         struct CadaclysmBlacksmithDraftPoint *out);

/**
 * Every face of `solid`'s draft against `pull` (3 doubles, normalised here), one row per face
 * in face order (Fusion's draft analysis): the body meshed at `tolerance`, each triangle's
 * angle read exactly at its centre and its area banded by `threshold` (radians, in
 * `[0, pi/2)`; Fusion's default is 1 degree), a triangle drafting either way casting a ray
 * along the way it releases -- one that meets the body is undercut. Null and `last_error`
 * (starting `draft_analysis: `) for a null solid or pull, a pull zero or not finite, a
 * threshold out of range, a tolerance negative or infinite, and a body with no faces.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `pull` 3 doubles. Free the result with
 * `cadaclysm_blacksmith_draft_analysis_free`.
 */
struct CadaclysmBlacksmithDraftAnalysis *cadaclysm_blacksmith_draft_analysis(const struct CadaclysmBlacksmithSolid *solid,
                                                                             const double *pull,
                                                                             double threshold,
                                                                             double tolerance);

/**
 * How many faces. 0 (and `last_error`) for null.
 *
 * # Safety
 * `analysis` live.
 */
uint32_t cadaclysm_blacksmith_draft_analysis_count(const struct CadaclysmBlacksmithDraftAnalysis *analysis);

/**
 * Face row `i` into `out`. `false` (and `last_error`) for a null `analysis`, a null `out`, or
 * `i` out of range; `out` is untouched then.
 *
 * # Safety
 * `analysis` live; `out` one `CadaclysmBlacksmithFaceDraft`.
 */
bool cadaclysm_blacksmith_draft_analysis_face(const struct CadaclysmBlacksmithDraftAnalysis *analysis,
                                              uint32_t i,
                                              struct CadaclysmBlacksmithFaceDraft *out);

/**
 * Release a draft analysis. Null is a no-op.
 *
 * # Safety
 * `analysis` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_draft_analysis_free(struct CadaclysmBlacksmithDraftAnalysis *analysis);

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
 * Sheet `id` (a `bim.sheet` node) as SVG text sized in paper millimetres: its frame, title
 * block and viewports (plans, sections, elevations, schedules and 3D views; a 3D view is drawn as its visible lines; a picture-style one, which only the web editor renders, as a box reading "3D view not rendered"). The
 * document is evaluated first if it is not. Owned: release it with [`cadaclysm_blacksmith_string_free`]. Null and
 * `last_error` for a node that is missing, not a sheet, or a sheet that did not build.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string.
 */
char *cadaclysm_bim_sheet_svg(struct CadaclysmBlacksmithDocument *doc,
                              const char *id);

/**
 * Sheet `id` (a `bim.sheet` node) as a one-page PDF the size of its paper, with a bookmark
 * naming it ("A-101 Plans"). A 3D view is drawn as its visible lines; a picture-style one,
 * which only the web editor renders, as a box reading "3D view not rendered". The document is
 * evaluated first if it is not. The bytes are
 * owned, their count written through `len`: release them with
 * [`cadaclysm_blacksmith_bytes_free`](crate::cadaclysm_blacksmith_bytes_free), passing that
 * `len` back. Null and `last_error` for a null `len`, or a node that is missing, not a sheet,
 * or a sheet that did not build.
 *
 * # Safety
 * `doc` a live document; `id` a NUL-terminated UTF-8 string; `len` a writable `size_t`.
 */
uint8_t *cadaclysm_bim_sheet_pdf(struct CadaclysmBlacksmithDocument *doc,
                                 const char *id,
                                 size_t *len);

/**
 * Sheets `ids_json` (a JSON list of `bim.sheet` ids, `["a101","a201"]`) as one PDF: a page each
 * in that order, each its paper's size, a bookmark a page. A 3D view is drawn as its visible
 * lines; a picture-style one, which only the web editor renders, as a box reading "3D view not rendered". The document
 * is evaluated first if it is not. Owned bytes as [`cadaclysm_bim_sheet_pdf`]'s. Null and `last_error` for a null
 * `len`, an empty list, ids that are not a JSON list of strings, or any sheet that call would
 * refuse.
 *
 * # Safety
 * `doc` a live document; `ids_json` a NUL-terminated UTF-8 string; `len` a writable `size_t`.
 */
uint8_t *cadaclysm_bim_sheets_pdf(struct CadaclysmBlacksmithDocument *doc,
                                  const char *ids_json,
                                  size_t *len);

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
 * Meshes the garment `g` and builds a cloth on an avatar mesh: `avatar_positions` are xyz
 * triples (`position_count` doubles, a multiple of 3), `avatar_indices` index triples
 * (`index_count`, a multiple of 3). Both counts 0 means no avatar, whatever the pointers;
 * exactly one count 0 is refused (positions and indices come together). `options` is null
 * for the defaults, else `CADACLYSM_BLACKSMITH_CLOTH_OPTIONS` (20) doubles. The cloth
 * does not keep `g`. Null and `last_error` on a refusal; free it with
 * [`cadaclysm_blacksmith_cloth_free`].
 *
 * # Safety
 * `g` a live garment; the avatar arrays `position_count` and `index_count` elements (or null
 * with a zero count); `options` null or 20 doubles.
 */
struct CadaclysmBlacksmithCloth *cadaclysm_blacksmith_cloth_new(const struct CadaclysmBlacksmithGarment *g,
                                                                const double *avatar_positions,
                                                                size_t position_count,
                                                                const uint32_t *avatar_indices,
                                                                size_t index_count,
                                                                const double *options);

/**
 * As [`cadaclysm_blacksmith_cloth_new`], with the avatar read from `len` bytes of a binary or
 * ASCII STL file.
 *
 * # Safety
 * `g` a live garment; `stl` `len` bytes; `options` null or 20 doubles.
 */
struct CadaclysmBlacksmithCloth *cadaclysm_blacksmith_cloth_new_stl(const struct CadaclysmBlacksmithGarment *g,
                                                                    const uint8_t *stl,
                                                                    size_t len,
                                                                    const double *options);

/**
 * Frees a cloth; null is a no-op. Every borrowed pointer it lent dies with it.
 *
 * # Safety
 * `c` must be null or a cloth not yet freed.
 */
void cadaclysm_blacksmith_cloth_free(struct CadaclysmBlacksmithCloth *c);

/**
 * Writes the options a new cloth starts with to `out` (`CADACLYSM_BLACKSMITH_CLOTH_OPTIONS`
 * doubles).
 *
 * # Safety
 * `out` room for 20 doubles.
 */
bool cadaclysm_blacksmith_cloth_default_options(double *out);

/**
 * Writes the cloth's options to `out` (`CADACLYSM_BLACKSMITH_CLOTH_OPTIONS` doubles).
 *
 * # Safety
 * `c` a live cloth; `out` room for 20 doubles.
 */
bool cadaclysm_blacksmith_cloth_options(const struct CadaclysmBlacksmithCloth *c, double *out);

/**
 * Sets the cloth's options from 20 doubles. `particle_distance` must equal the cloth's: the
 * mesh is not rebuilt. False and `last_error` on a refusal (the options are then unchanged).
 *
 * # Safety
 * `c` a live cloth; `options` 20 doubles.
 */
bool cadaclysm_blacksmith_cloth_set_options(struct CadaclysmBlacksmithCloth *c,
                                            const double *options);

/**
 * Advances the simulation by `frames` frames (each `frame_dt` seconds). Borrowed lists lent
 * before the call are no longer valid.
 *
 * # Safety
 * `c` a live cloth.
 */
bool cadaclysm_blacksmith_cloth_step(struct CadaclysmBlacksmithCloth *c, uint32_t frames);

/**
 * Writes the status to `out` (`CADACLYSM_BLACKSMITH_CLOTH_STATUS` doubles): `{frame,
 * vertices, triangles, seam_pairs, welded_pairs, non_finite, dropped, max_speed}`. `seam_pairs`
 * is the seam pairs in the sim mesh: sewing is done when `welded_pairs == seam_pairs`.
 *
 * # Safety
 * `c` a live cloth; `out` room for 8 doubles.
 */
bool cadaclysm_blacksmith_cloth_status(const struct CadaclysmBlacksmithCloth *c, double *out);

/**
 * The current position of every sim vertex, xyz triples in mm: `count` is the number of
 * floats (3 per vertex). Borrowed: the pointer is valid until the next call on the cloth or
 * its free (callers copy); `cadaclysm_blacksmith_cloth_remesh_pattern` changes the counts.
 * Null and `last_error` for a null cloth.
 *
 * # Safety
 * `c` a live cloth; `count` null or room for one `size_t`.
 */
const float *cadaclysm_blacksmith_cloth_positions(struct CadaclysmBlacksmithCloth *c,
                                                  size_t *count);

/**
 * The triangles as sim-vertex indices, 3 per triangle: `count` is the number of indices.
 * Borrowed: valid until the next call on the cloth or its free (callers copy);
 * `cadaclysm_blacksmith_cloth_remesh_pattern` changes the counts. Null for a null cloth.
 *
 * # Safety
 * `c` a live cloth; `count` null or room for one `size_t`.
 */
const uint32_t *cadaclysm_blacksmith_cloth_triangles(struct CadaclysmBlacksmithCloth *c,
                                                     size_t *count);

/**
 * Each sim vertex's arranged start position in 3D, xyz triples in mm: `count` is the number
 * of floats. Borrowed: valid until the next call on the cloth or its free (callers copy);
 * `cadaclysm_blacksmith_cloth_remesh_pattern` changes the counts. Null for a null cloth.
 *
 * # Safety
 * `c` a live cloth; `count` null or room for one `size_t`.
 */
const float *cadaclysm_blacksmith_cloth_rest(struct CadaclysmBlacksmithCloth *c, size_t *count);

/**
 * The pattern id each sim vertex belongs to: `count` is the number of vertices. Borrowed:
 * valid until the next call on the cloth or its free (callers copy);
 * `cadaclysm_blacksmith_cloth_remesh_pattern` changes the counts. Null for a null cloth.
 *
 * # Safety
 * `c` a live cloth; `count` null or room for one `size_t`.
 */
const uint32_t *cadaclysm_blacksmith_cloth_vertex_patterns(struct CadaclysmBlacksmithCloth *c,
                                                           size_t *count);

/**
 * Each sim vertex's exact absolute position on its pattern, (u, v) pairs in mm: `count` is
 * the number of doubles (2 per vertex). Borrowed: valid until the next call on the cloth or
 * its free (callers copy); `cadaclysm_blacksmith_cloth_remesh_pattern` changes the counts.
 * Null for a null cloth.
 *
 * # Safety
 * `c` a live cloth; `count` null or room for one `size_t`.
 */
const double *cadaclysm_blacksmith_cloth_vertex_links(struct CadaclysmBlacksmithCloth *c,
                                                      size_t *count);

/**
 * Writes vertex `vertex`'s link to `out`: `{pattern, u, v}`. False for a vertex that is not a
 * sim vertex.
 *
 * # Safety
 * `c` a live cloth; `out` room for 3 doubles.
 */
bool cadaclysm_blacksmith_cloth_vertex_link(const struct CadaclysmBlacksmithCloth *c,
                                            uint32_t vertex,
                                            double *out);

/**
 * Pins vertex `vertex` at `at` (3 doubles, mm), or where it is now when `at` is null. False
 * for a vertex that is not a sim vertex.
 *
 * # Safety
 * `c` a live cloth; `at` null or 3 doubles.
 */
bool cadaclysm_blacksmith_cloth_pin(struct CadaclysmBlacksmithCloth *c,
                                    uint32_t vertex,
                                    const double *at);

/**
 * Releases a pin. False for a vertex that is not a sim vertex.
 *
 * # Safety
 * `c` a live cloth.
 */
bool cadaclysm_blacksmith_cloth_unpin(struct CadaclysmBlacksmithCloth *c, uint32_t vertex);

/**
 * Drags vertex `vertex` towards `target` (3 doubles, mm); a null `target` releases the drag.
 * False for a vertex that is not a sim vertex.
 *
 * # Safety
 * `c` a live cloth; `target` null or 3 doubles.
 */
bool cadaclysm_blacksmith_cloth_drag(struct CadaclysmBlacksmithCloth *c,
                                     uint32_t vertex,
                                     const double *target);

/**
 * Re-meshes pattern `pattern` after its outline changed in garment `g`. The vertex and
 * triangle counts may change, so every borrowed pointer lent before is dead and callers
 * re-read the lists.
 *
 * # Safety
 * `c` a live cloth; `g` a live garment.
 */
bool cadaclysm_blacksmith_cloth_remesh_pattern(struct CadaclysmBlacksmithCloth *c,
                                               const struct CadaclysmBlacksmithGarment *g,
                                               uint32_t pattern);

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
 * A new, empty garment. Free it with [`cadaclysm_blacksmith_garment_free`].
 */
struct CadaclysmBlacksmithGarment *cadaclysm_blacksmith_garment_new(void);

/**
 * Frees a garment; null is a no-op. Every borrowed pointer it lent dies with it.
 *
 * # Safety
 * `g` must be null or a garment not yet freed.
 */
void cadaclysm_blacksmith_garment_free(struct CadaclysmBlacksmithGarment *g);

/**
 * Adds a fabric called `name` with `CADACLYSM_BLACKSMITH_GARMENT_FABRIC_PARAMS` (20)
 * parameters: its id, or `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `g` a live garment; `name` a NUL-terminated UTF-8 string; `params` 20 doubles.
 */
uint32_t cadaclysm_blacksmith_garment_add_fabric(struct CadaclysmBlacksmithGarment *g,
                                                 const char *name,
                                                 const double *params);

/**
 * Writes fabric `id`'s 20 parameters to `out`. False for an unknown id.
 *
 * # Safety
 * `g` a live garment; `out` room for 20 doubles.
 */
bool cadaclysm_blacksmith_garment_fabric_params(const struct CadaclysmBlacksmithGarment *g,
                                                uint32_t id,
                                                double *out);

/**
 * Fabric `id`'s name. Owned: free it with `cadaclysm_blacksmith_string_free`. Null for an
 * unknown id.
 *
 * # Safety
 * `g` a live garment.
 */
char *cadaclysm_blacksmith_garment_fabric_name(const struct CadaclysmBlacksmithGarment *g,
                                               uint32_t id);

/**
 * Adds a pattern called `name` with the closed `outline` (its holes are kept), the grain
 * direction (`grain_x`, `grain_y`), the fabric id, a `layer` (stacking order) and the seam
 * allowance: `count` widths, either 1 (every side) or one per side. Its id, or
 * `CADACLYSM_BLACKSMITH_NONE`. The pattern starts on the origin, flat.
 *
 * # Safety
 * `g` a live garment; `name` a NUL-terminated UTF-8 string; `outline` a live profile;
 * `allowance` `count` doubles.
 */
uint32_t cadaclysm_blacksmith_garment_add_pattern(struct CadaclysmBlacksmithGarment *g,
                                                  const char *name,
                                                  const struct CadaclysmBlacksmithProfile *outline,
                                                  double grain_x,
                                                  double grain_y,
                                                  uint32_t fabric,
                                                  int32_t layer,
                                                  const double *allowance,
                                                  size_t count);

/**
 * Pattern `id`'s name. Owned: free it with `cadaclysm_blacksmith_string_free`. Null for an
 * unknown id.
 *
 * # Safety
 * `g` a live garment.
 */
char *cadaclysm_blacksmith_garment_pattern_name(const struct CadaclysmBlacksmithGarment *g,
                                                uint32_t id);

/**
 * Pattern `id`'s outline as a new profile: free it with `cadaclysm_blacksmith_profile_free`.
 * Null for an unknown id.
 *
 * # Safety
 * `g` a live garment.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_garment_pattern_outline(const struct CadaclysmBlacksmithGarment *g,
                                                                                uint32_t id);

/**
 * Writes pattern `id`'s `{grain_x, grain_y, fabric, layer}` to `out[0..4]`. False for an
 * unknown id.
 *
 * # Safety
 * `g` a live garment; `out` room for 4 doubles.
 */
bool cadaclysm_blacksmith_garment_pattern_info(const struct CadaclysmBlacksmithGarment *g,
                                               uint32_t id,
                                               double *out);

/**
 * Pattern `id`'s seam allowances, one per side; borrowed, `count` set. Null for an unknown id.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it. Never null on
 * success (`count` 0 when empty).
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const double *cadaclysm_blacksmith_garment_pattern_allowance(struct CadaclysmBlacksmithGarment *g,
                                                             uint32_t id,
                                                             size_t *count);

/**
 * Places pattern `id` in space: `frame` is 12 doubles, the origin then the x, y and z axes.
 * False for an unknown id or a value that is not finite.
 *
 * # Safety
 * `g` a live garment; `frame` 12 doubles.
 */
bool cadaclysm_blacksmith_garment_pattern_set_frame(struct CadaclysmBlacksmithGarment *g,
                                                    uint32_t id,
                                                    const double *frame);

/**
 * Writes pattern `id`'s frame (origin, x, y, z axes) to `out[0..12]`. False for an unknown id.
 *
 * # Safety
 * `g` a live garment; `out` room for 12 doubles.
 */
bool cadaclysm_blacksmith_garment_pattern_frame(const struct CadaclysmBlacksmithGarment *g,
                                                uint32_t id,
                                                double *out);

/**
 * Wraps pattern `id` round a cylinder: `wrap` is 7 doubles, `{ox, oy, oz, dx, dy, dz, radius}`
 * (a point on the axis, the axis direction, the radius). Null clears the wrap. False for an
 * unknown id, a radius not above 0 or a zero direction.
 *
 * # Safety
 * `g` a live garment; `wrap` null or 7 doubles.
 */
bool cadaclysm_blacksmith_garment_pattern_set_wrap(struct CadaclysmBlacksmithGarment *g,
                                                   uint32_t id,
                                                   const double *wrap);

/**
 * Adds a notch to pattern `id` at arc length `at` along its outline: `kind` is one of the
 * `CADACLYSM_BLACKSMITH_GARMENT_NOTCH_*` codes, `depth` how far it cuts. False on failure.
 *
 * # Safety
 * `g` a live garment.
 */
bool cadaclysm_blacksmith_garment_pattern_add_notch(struct CadaclysmBlacksmithGarment *g,
                                                    uint32_t id,
                                                    double at,
                                                    uint32_t kind,
                                                    double depth);

/**
 * Pattern `id`'s notches as triples `{at, kind, depth}`; borrowed, `count` set (a multiple
 * of 3). Null for an unknown id.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it. Never null on
 * success (`count` 0 when empty).
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const double *cadaclysm_blacksmith_garment_pattern_notches(struct CadaclysmBlacksmithGarment *g,
                                                           uint32_t id,
                                                           size_t *count);

/**
 * Adds an internal line to pattern `id`: `kind` is one of the
 * `CADACLYSM_BLACKSMITH_GARMENT_INTERNAL_*` codes, `path` a profile read as an open path:
 * the profile's segments are copied as given (a closed profile keeps its closing segment);
 * holes are ignored. False on failure.
 *
 * # Safety
 * `g` a live garment; `path` a live profile.
 */
bool cadaclysm_blacksmith_garment_pattern_add_internal(struct CadaclysmBlacksmithGarment *g,
                                                       uint32_t id,
                                                       uint32_t kind,
                                                       const struct CadaclysmBlacksmithProfile *path);

/**
 * Sews pattern `pa` between arc lengths `a_from` and `a_to` to pattern `pb` between `b_from`
 * and `b_to`; `reversed` sews them against each other's direction. The seam's id, or
 * `CADACLYSM_BLACKSMITH_NONE`.
 *
 * # Safety
 * `g` a live garment.
 */
uint32_t cadaclysm_blacksmith_garment_add_seam(struct CadaclysmBlacksmithGarment *g,
                                               uint32_t pa,
                                               double a_from,
                                               double a_to,
                                               uint32_t pb,
                                               double b_from,
                                               double b_to,
                                               bool reversed);

/**
 * Writes seam `id` as `{pa, a_from, a_to, pb, b_from, b_to, reversed}` to `out[0..7]`
 * (`reversed` is 0 or 1). False for an unknown id.
 *
 * # Safety
 * `g` a live garment; `out` room for 7 doubles.
 */
bool cadaclysm_blacksmith_garment_seam(const struct CadaclysmBlacksmithGarment *g,
                                       uint32_t id,
                                       double *out);

/**
 * Removes pattern `id` and every seam that names it. False for an unknown id.
 *
 * # Safety
 * `g` a live garment.
 */
bool cadaclysm_blacksmith_garment_remove_pattern(struct CadaclysmBlacksmithGarment *g, uint32_t id);

/**
 * Removes seam `id`. False for an unknown id.
 *
 * # Safety
 * `g` a live garment.
 */
bool cadaclysm_blacksmith_garment_remove_seam(struct CadaclysmBlacksmithGarment *g, uint32_t id);

/**
 * The live pattern ids, ascending; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it. Never null on
 * success (`count` 0 when empty).
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_garment_patterns(struct CadaclysmBlacksmithGarment *g,
                                                      size_t *count);

/**
 * The live seam ids, ascending; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it. Never null on
 * success (`count` 0 when empty).
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_garment_seams(struct CadaclysmBlacksmithGarment *g,
                                                   size_t *count);

/**
 * The live fabric ids, ascending; borrowed, `count` set. Null on failure.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it. Never null on
 * success (`count` 0 when empty).
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_garment_fabrics(struct CadaclysmBlacksmithGarment *g,
                                                     size_t *count);

/**
 * Checks the garment at `accuracy` (a fraction in (0, 1) that sets how finely outlines are
 * measured) and caches the issues for [`cadaclysm_blacksmith_garment_issue`]: the issue
 * count. `CADACLYSM_BLACKSMITH_NONE` only for a null garment: a bad accuracy becomes an
 * `UNMEASURABLE` issue, not a failure. Any mutating call clears the cache.
 *
 * # Safety
 * `g` a live garment.
 */
uint32_t cadaclysm_blacksmith_garment_validate(struct CadaclysmBlacksmithGarment *g,
                                               double accuracy);

/**
 * Writes issue `i` of the last validation as `{severity, kind, ratio}` to `out[0..3]`: the
 * `CADACLYSM_BLACKSMITH_GARMENT_SEVERITY_*` and `_ISSUE_*` codes, and the seam-length
 * mismatch's length ratio (NaN for every other kind). False, with "call garment_validate
 * first" in `last_error`, when no validation is cached (any mutating call clears it), or
 * for an `i` past the issue count.
 *
 * # Safety
 * `g` a live garment; `out` room for 3 doubles.
 */
bool cadaclysm_blacksmith_garment_issue(const struct CadaclysmBlacksmithGarment *g,
                                        uint32_t i,
                                        double *out);

/**
 * Issue `i`'s message. Owned: free it with `cadaclysm_blacksmith_string_free`. Null when no
 * validation is cached or `i` is past the issue count.
 *
 * # Safety
 * `g` a live garment.
 */
char *cadaclysm_blacksmith_garment_issue_message(const struct CadaclysmBlacksmithGarment *g,
                                                 uint32_t i);

/**
 * A pattern's cut line (its sew line grown by the allowance) as `xy` pairs, flattened to
 * `tolerance`; borrowed, `count` set to the number of doubles (twice the points). Null on
 * failure.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it.
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const double *cadaclysm_blacksmith_garment_cut_line(struct CadaclysmBlacksmithGarment *g,
                                                    uint32_t pattern,
                                                    double tolerance,
                                                    size_t *count);

/**
 * The part of a pattern's outline between arc lengths `from` and `to` as `xy` pairs,
 * flattened to `tolerance`; borrowed, `count` set to the number of doubles. Null on failure.
 *
 * Borrowed: valid until the next call on this garment or its free; copy it.
 *
 * # Safety
 * `g` a live garment; `count` null or writable.
 */
const double *cadaclysm_blacksmith_garment_range_points(struct CadaclysmBlacksmithGarment *g,
                                                        uint32_t pattern,
                                                        double from,
                                                        double to,
                                                        double tolerance,
                                                        size_t *count);

/**
 * The garment's patterns as an AAMA DXF, curves flattened to `tolerance`, with `author` in
 * the header (null or empty for none). AAMA output is written as metric, so a garment from a
 * non-millimetre document must be converted to millimetres first. Owned: free it with `cadaclysm_blacksmith_string_free`.
 * Null on failure.
 *
 * # Safety
 * `g` a live garment; `author` null or a NUL-terminated UTF-8 string.
 */
char *cadaclysm_blacksmith_garment_to_aama(const struct CadaclysmBlacksmithGarment *g,
                                           double tolerance,
                                           const char *author);

/**
 * A garment read from AAMA DXF `text`: its patterns over one fabric, id 0, called
 * "imported", with all-zero parameters. Free it with [`cadaclysm_blacksmith_garment_free`].
 * Null on failure.
 *
 * # Safety
 * `text` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithGarment *cadaclysm_blacksmith_garment_from_aama(const char *text);

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
 * shells, splits, sections, hits, closest, closest points from a point or a curve,
 * projectors, the nearest object to a curve, classifiers, colliders, clash, meshes, curve fits
 * and projections, profile verbs, holes, ribs and webs, patterns, point and edge queries, threads): the verb works at the inputs' **effective** tolerance,
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
 * The option `tolerance.angular` (default 1 degree) applies where nothing declares an angle:
 * an angular tolerance 0 or NaN (edge convexity, tangent chains) is the loosest angle the
 * solids declare, else that option.
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
 * Give the solid's free-form surfaces and edge curves their analytic kind: a NURBS (or
 * revolved, extruded or swept) surface that is a plane, cylinder, cone, sphere or torus within
 * `tolerance` of every sample of its faces and every point of their edges becomes exactly that,
 * and an edge curve that is a line, circle or ellipse within it likewise, over the same stretch
 * run the same way. Faces and edges keep their numbers. `solid` is left as it was; the new
 * solid keeps its name and colours. `NaN` or `tolerance <= 0` takes the default, `1e-6` times
 * the body's extent -- not the file's declared tolerance, at which a fillet's blend reads as a
 * torus; the summary's `sizes[0]` says what was used.
 *
 * A report handle, read with the `cadaclysm_blacksmith_recognize_*` accessors and freed with
 * [`cadaclysm_blacksmith_recognize_free`]; null (and `last_error`) on a null `solid`.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithRecognize *cadaclysm_blacksmith_recognized(const struct CadaclysmBlacksmithSolid *solid,
                                                                     double tolerance);

/**
 * The recognised solid: a new solid the caller frees with
 * [`cadaclysm_blacksmith_solid_free`](crate::cadaclysm_blacksmith_solid_free), each call a
 * solid of its own (sharing the body, not copying it). It outlives the report. Null (and
 * `last_error`) on a null `r`.
 *
 * # Safety
 * `r` null or live from [`cadaclysm_blacksmith_recognized`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_recognize_body(const struct CadaclysmBlacksmithRecognize *r);

/**
 * Free a report. Null is a no-op. A solid taken with [`cadaclysm_blacksmith_recognize_body`]
 * stays good.
 *
 * # Safety
 * `r` null or from [`cadaclysm_blacksmith_recognized`], and freed once.
 */
void cadaclysm_blacksmith_recognize_free(struct CadaclysmBlacksmithRecognize *r);

/**
 * The report's figures. `counts`, ten `uint32_t`, in order: faces taken as planes, cylinders,
 * cones, spheres, tori; faces left free-form; edges taken as lines, circles, ellipses; edges
 * left free-form. `sizes`, three `double`: the tolerance used, the worst face deviation, the
 * worst edge deviation (0 where none was taken). Either output may be null; not both. `false`
 * (and `last_error`) on a null `r` or both outputs null.
 *
 * # Safety
 * `r` null or live from [`cadaclysm_blacksmith_recognized`]; `counts` null or ten `uint32_t`;
 * `sizes` null or three `double`.
 */
bool cadaclysm_blacksmith_recognize_summary(const struct CadaclysmBlacksmithRecognize *r,
                                            uint32_t *counts,
                                            double *sizes);

/**
 * The faces taken, one row each: `items`, two `uint32_t` -- the face's index (unchanged by
 * recognition), its kind (0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus); `sizes`, one
 * `double` -- the furthest any sample of it lies from the analytic surface. Returns the count;
 * with both buffers null it writes nothing, so call it twice: once to size the buffers, once to
 * fill them. A non-null buffer must hold the whole count. Zero (and `last_error`) on a null `r`.
 *
 * # Safety
 * `r` null or live from [`cadaclysm_blacksmith_recognized`]; `items` null or `2 n` `uint32_t`,
 * `sizes` null or `n` `double`, for `n` the count.
 */
uint32_t cadaclysm_blacksmith_recognize_faces(const struct CadaclysmBlacksmithRecognize *r,
                                              uint32_t *items,
                                              double *sizes);

/**
 * The free-form faces left, one row each: `items`, two `uint32_t` -- the face's index, why (0
 * no kind fits within the tolerance, 1 its normals point both ways, 2 a parameter trim cannot
 * be lifted, 3 too few samples); `sizes`, one `double` -- for "no kind", the closest kind's
 * deviation, else `NaN`. Returns the count, with the two-call convention of
 * [`cadaclysm_blacksmith_recognize_faces`].
 *
 * # Safety
 * `r` null or live; `items` null or `2 n` `uint32_t`, `sizes` null or `n` `double`.
 */
uint32_t cadaclysm_blacksmith_recognize_refused(const struct CadaclysmBlacksmithRecognize *r,
                                                uint32_t *items,
                                                double *sizes);

/**
 * The edges whose curve was taken, one row each, in edge order: `items`, two `uint32_t` -- the
 * brep edge id (as [`cadaclysm_blacksmith_edge_tolerance`](crate::cadaclysm_blacksmith_edge_tolerance)
 * takes one), its kind (0 line, 1 circle, 2 ellipse); `sizes`, one `double` -- the furthest any
 * point of the curve or its edges lies from the analytic curve. Returns the count, with the
 * two-call convention of [`cadaclysm_blacksmith_recognize_faces`].
 *
 * # Safety
 * `r` null or live; `items` null or `2 n` `uint32_t`, `sizes` null or `n` `double`.
 */
uint32_t cadaclysm_blacksmith_recognize_edges(const struct CadaclysmBlacksmithRecognize *r,
                                              uint32_t *items,
                                              double *sizes);

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
 * The defaults: the front view (looking along +Y, Z up), parallel, at the solids'
 * effective tolerance, smooth edges within one degree, mesh features past thirty, no
 * isocurves.
 *
 * # Safety
 * `options` must be null or writable.
 */
void cadaclysm_blacksmith_hlr_options_init(struct CadaclysmBlacksmithHlrOptions *options);

/**
 * Hidden-line removal of `count` solids, each where it stands: every solid draws its
 * edges and silhouettes and hides the others'. Exact in its curves -- each line a span of
 * an edge's own curve or a silhouette, as rational cubic Béziers -- and classified by a ray
 * toward the eye from each piece between crossings. Seams are never drawn. A view
 * coordinate is in the camera's axes (x right, y up), the origin on the sight line through
 * the centre of the solids' box (parallel), or `(x / depth, y / depth)` (perspective).
 *
 * Null and `last_error` for no solids, a null solid or options, and words refused: a
 * projection that is neither, a direction or `up` of no length or not finite, `up` along
 * the view, the eye on its target, a tolerance negative or infinite, an angle outside 0 to
 * pi/2, more than 1000 isocurves. Free the result with [`cadaclysm_blacksmith_hlr_free`].
 *
 * # Safety
 * `solids` `count` live solids; `options` a struct filled by
 * [`cadaclysm_blacksmith_hlr_options_init`].
 */
struct CadaclysmBlacksmithHlr *cadaclysm_blacksmith_hlr(const struct CadaclysmBlacksmithSolid *const *solids,
                                                        size_t count,
                                                        const struct CadaclysmBlacksmithHlrOptions *options);

/**
 * Hidden-line removal of `count` triangle meshes, each a solid of flat triangles: its
 * lines are the edges whose two triangles turn by more than `feature_angle`, the edges of
 * one triangle, and the edges between a triangle facing the eye and one facing away
 * (outlines), chained through vertices; the triangles hide exactly. `smooth_angle` and
 * `iso` are not read. Refused as [`cadaclysm_blacksmith_hlr`], with "no meshes" and "null
 * mesh".
 *
 * # Safety
 * `meshes` `count` live meshes; `options` as `cadaclysm_blacksmith_hlr`.
 */
struct CadaclysmBlacksmithHlr *cadaclysm_blacksmith_hlr_mesh(const struct CadaclysmBlacksmithTriangleMesh *const *meshes,
                                                             size_t count,
                                                             const struct CadaclysmBlacksmithHlrOptions *options);

/**
 * How many lines the view has. 0 and `last_error` for a null view.
 *
 * # Safety
 * `hlr` null or live.
 */
uint32_t cadaclysm_blacksmith_hlr_line_count(const struct CadaclysmBlacksmithHlr *hlr);

/**
 * Line `i`'s record into `out`. `false` and `last_error` for a null argument or `i` past
 * the end.
 *
 * # Safety
 * `hlr` null or live; `out` null or writable.
 */
bool cadaclysm_blacksmith_hlr_line(const struct CadaclysmBlacksmithHlr *hlr,
                                   uint32_t i,
                                   struct CadaclysmBlacksmithHlrLine *out);

/**
 * Line `i` on the view plane as rational cubic Béziers into `out`, sixteen doubles each --
 * `x y z w` per control point, `z` 0 -- `bezier_count` of them (see
 * [`cadaclysm_blacksmith_hlr_line`]), each starting where the one before ends. `false` and
 * `last_error` for a null argument or `i` past the end.
 *
 * # Safety
 * `hlr` null or live; `out` null or room for `16 * bezier_count` doubles.
 */
bool cadaclysm_blacksmith_hlr_line_beziers2d(const struct CadaclysmBlacksmithHlr *hlr,
                                             uint32_t i,
                                             double *out);

/**
 * Line `i` in space, as [`cadaclysm_blacksmith_hlr_line_beziers2d`] writes it on the view
 * plane: Bézier for Bézier the same span, the view-plane one its projection parameter for
 * parameter.
 *
 * # Safety
 * `hlr` null or live; `out` null or room for `16 * bezier_count` doubles.
 */
bool cadaclysm_blacksmith_hlr_line_beziers3d(const struct CadaclysmBlacksmithHlr *hlr,
                                             uint32_t i,
                                             double *out);

/**
 * What the view's hidden-line removal did, into `out`. `false` and `last_error` for a null
 * argument.
 *
 * # Safety
 * `hlr` null or live; `out` null or writable.
 */
bool cadaclysm_blacksmith_hlr_report(const struct CadaclysmBlacksmithHlr *hlr,
                                     struct CadaclysmBlacksmithHlrReport *out);

/**
 * Release a view. Null is a no-op.
 *
 * # Safety
 * `hlr` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_hlr_free(struct CadaclysmBlacksmithHlr *hlr);

/**
 * The boundary of the union of the solids' projections, as closed profiles on the view
 * plane (view coordinates, as [`cadaclysm_blacksmith_hlr`]'s): each outer loop
 * counter-clockwise with the holes inside it clockwise -- a through hole seen along its
 * axis is a hole. Read it with `cadaclysm_blacksmith_profile_list_count` / `_get`; free it
 * with `cadaclysm_blacksmith_profile_list_free`. Nothing seen is a list of 0. Refused as
 * [`cadaclysm_blacksmith_hlr`].
 *
 * # Safety
 * As [`cadaclysm_blacksmith_hlr`].
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_projected_outline(const struct CadaclysmBlacksmithSolid *const *solids,
                                                                              size_t count,
                                                                              const struct CadaclysmBlacksmithHlrOptions *options);

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
 * What is wrong with `a` (and `b`, if not null) as the arguments of `operation`, at
 * `tolerance`: OCCT's `BRepAlgoAPI_Check`, gathered from what the kernel already
 * measures. Read the findings with [`cadaclysm_blacksmith_check_count`] and
 * [`cadaclysm_blacksmith_check_finding`]; none at all is a valid pair. A handle,
 * never null, for any pair the check could run on.
 *
 * Every argument is checked alone, whatever the operation: `"no_faces"`; the features
 * smaller than `tolerance` (`"short_edge"`: `index` the edge, `size` its length;
 * `"collapsed_edge"`: `index` the trim; `"sliver_face"`: `index` the face, `size` its
 * width; `"tiny_face"`: `index` the face, `size` its area; `"tiny_body"`: `size` its
 * diagonal; `"small_hole"`: `index` the loop, `size` its area or width -- as
 * `cadaclysm_blacksmith_health` finds them); `"loose_edge"` (`index` the edge, `size` how
 * far its sides part); `"curve_on_surface"` (an edge whose 2D trim through the surface,
 * curve or polyline in space leaves a face's surface, or parts from the others there, by
 * more than the larger of `tolerance` and the edge's recorded tolerance: `index` the edge
 * -- a trim naming none: the trim -- `other` the face, `size` the largest deviation);
 * `"c0_inside"` (a crease where the geometry is only C0, sharper than the angular
 * tolerance -- the solid's declared one, else the `"tolerance.angular"` option: inside a
 * face, `index` the face and `other` `CADACLYSM_BLACKSMITH_NONE`; along an edge's own
 * curve, `index` the edge and `other` the lowest-numbered face it bounds; `size` the
 * largest angle in radians; a knot where the two sides meet tangent is none); and where it
 * passes through itself, as
 * `cadaclysm_blacksmith_self_intersect` finds it (`"self_intersection"`: `index` and
 * `other` the two faces, the same face for a fold, `size` the crossing's length;
 * `"self_overlap"`: `index` and `other` two faces lying on one another; `"unmeshable"` if
 * it could not be meshed to look). `operation` (null or empty for none) adds what that
 * verb refuses each argument for: `"join"`, `"cut"` and `"common"` want both closed
 * (`"open"`: one finding per free edge, `index` the edge -- `CADACLYSM_BLACKSMITH_NONE`
 * for a trim naming none -- `other` its face, `size` its length) and holding no region
 * wall (`"region_wall"`, a merge's body); `"split_sheet"` and `"trim"` want only the tool
 * (`b`) closed, neither walled; `"merge"` wants both closed manifolds (`"non_manifold"`)
 * of planes, cylinders, cones, spheres and tori (`"face_kind"`: `index` the face);
 * `"intersect"` wants nothing. With `b` null and an operation, `a` is held to what the
 * operation asks of its first argument. A free edge is no finding without an operation
 * that asks for a closed solid: an open sheet is a fine body.
 *
 * With `b`, the pair's sub-shapes a boolean would merge or struggle with are found too,
 * whatever the operation, each finding with `argument` 0, `index` in `a` and `other` in
 * `b`: `"merge_vertex"` (a vertex of each further apart than the weld, 1e-6, but within
 * `tolerance`: the two vertices as `cadaclysm_blacksmith_vertex_ref` numbers them, `size`
 * their distance); `"merge_edge"` (an edge of each running along one another within
 * `tolerance` and parallel within the angular tolerance over a stretch longer than
 * `tolerance`, not one edge: the edge ids, `size` the largest gap); `"merge_face"` (a face
 * of each lying on one another only within `tolerance`: the faces, `size` the largest
 * separation on the shared region's boundary); `"tangent_face"` (a face of each whose
 * crossing runs where their normals are parallel within the angular tolerance -- a
 * cylinder lying on a block: the faces, `size` the tangent stretch's length). The last
 * two are read off `cadaclysm_blacksmith_intersect`'s answer, so a point contact, which
 * has no crossing chain, is not found. Exactly coincident vertices, edges and faces are
 * none.
 *
 * Findings come argument by argument, in the order the kinds are listed above within
 * each, then the pair's.
 *
 * Reports its phases to `progress` if not null: "health", "curve_on_surface" and
 * "continuity" for each argument, then the self-intersection's "mesh", "cull", "cross",
 * "snap", "curve"; with `b`, "pairs" three times (vertices, edges, faces).
 *
 * Refuses `check: null solid`, `check: operation is not UTF-8`, `check: unknown
 * operation "<name>" (join, cut, common, split_sheet, trim, merge or intersect)` and
 * `check: tolerance must be positive and finite`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a` a live solid; `b` null or a live solid; `operation` null or a NUL-terminated
 * string; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithCheck *cadaclysm_blacksmith_check(const struct CadaclysmBlacksmithSolid *a,
                                                            const struct CadaclysmBlacksmithSolid *b,
                                                            const char *operation,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

/**
 * Release a check result. Null is a no-op.
 *
 * # Safety
 * `check` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_check_free(struct CadaclysmBlacksmithCheck *check);

/**
 * How many findings. 0 (and `last_error`) for null.
 *
 * # Safety
 * `check` live.
 */
uint32_t cadaclysm_blacksmith_check_count(const struct CadaclysmBlacksmithCheck *check);

/**
 * Finding `i` into `out`. `false` (and `last_error`) for a null `check`, a null `out`, or
 * `i` out of range.
 *
 * # Safety
 * `check` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_check_finding(const struct CadaclysmBlacksmithCheck *check,
                                        uint32_t i,
                                        struct CadaclysmBlacksmithFinding *out);

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
 * Where `solid` passes through itself, at `tolerance`: the same result as
 * [`cadaclysm_blacksmith_intersect`] with `solid` on both sides, read and freed the
 * same way. Never along its own topology -- two faces meeting at their shared edges
 * and vertices are not a crossing, so a clean solid is a handle with zero chains and
 * zero overlaps, never null. A chain's `face_a` and `face_b` are both faces of
 * `solid`; where they are the same face, the face folds through itself, and that
 * chain has no curve (`has_curve` false). An overlap is two faces of the solid lying
 * on one another.
 *
 * The solid is meshed once and crossed against itself on the mesh; where two faces'
 * meshes cross, the exact face-pair engine refines the chain. The mesh route's known
 * limit holds: a crossing narrower than `tolerance` -- two faces passing within it
 * without their meshes crossing -- can be missed. `tolerance` is the mesh tolerance,
 * expected well below the solid's extent, as `intersect`'s.
 *
 * Reports its phases to `progress` if not null: "mesh", "cull", "cross", "snap",
 * "curve".
 *
 * Refuses `self_intersect: null solid`, `self_intersect: tolerance must be positive
 * and finite`, `self_intersect: the solid has no faces`, `self_intersect: the solid
 * meshes to nothing`.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` a live solid; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_self_intersect(const struct CadaclysmBlacksmithSolid *solid,
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
 * Where `p` (3 doubles) lies against face `face` of `solid`, into `out`: its nearest point of the
 * face (exact, trimmed) and `where` 0 inside, 1 on the boundary, 2 off. Returns 1 where the point
 * is on the face (inside or on its boundary), 0 where it is off -- `out` filled either way --
 * and -1 on a refusal (negative: test `< 0`), with `last_error` set and `out` untouched, for a
 * null solid, `p` or `out`, a face out of range, a non-finite point, a tolerance negative or
 * infinite, or a face that gives no nearest point. Fusion's `isPointOnFace`, Rhino's
 * `IsPointOnFace`.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live; `p` null or 3 doubles; `out` null or one `CadaclysmBlacksmithFacePoint`.
 */
int32_t cadaclysm_blacksmith_face_point(const struct CadaclysmBlacksmithSolid *solid,
                                        uint32_t face,
                                        const double *p,
                                        double tolerance,
                                        struct CadaclysmBlacksmithFacePoint *out);

/**
 * A point strictly inside face `face` of `solid`'s trims, on its surface, into `out` (`where`
 * 0, `distance` 0): the centre of the largest circle inside one of the face's measuring-mesh
 * triangles that reads inside. Fusion's `pointOnFace`. False (and `last_error`), `out`
 * untouched, for a null solid or `out`, a face out of range, or a face where no point inside is
 * found.
 *
 * # Safety
 * `solid` null or live; `out` null or one `CadaclysmBlacksmithFacePoint`.
 */
bool cadaclysm_blacksmith_face_inner_point(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t face,
                                           struct CadaclysmBlacksmithFacePoint *out);

/**
 * The nearest point to `p` (3 doubles) of edge `edge` of `solid` on its own curve over its range,
 * into `out`, `on` where it is within `tolerance`. Returns 1 where the point is on the edge, 0
 * where it is not -- `out` filled either way -- and -1 on a refusal (negative: test `< 0`), with
 * `last_error` set and `out` untouched, for a null solid, `p` or `out`, an edge out of range, a
 * non-finite point, or a tolerance negative or infinite.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live; `p` null or 3 doubles; `out` null or one `CadaclysmBlacksmithEdgePoint`.
 */
int32_t cadaclysm_blacksmith_edge_point(const struct CadaclysmBlacksmithSolid *solid,
                                        uint32_t edge,
                                        const double *p,
                                        double tolerance,
                                        struct CadaclysmBlacksmithEdgePoint *out);

/**
 * A point on edge `edge` of `solid`, into `out` (`on` true, `distance` 0): its curve at the
 * middle of its range (a whole circle half a turn from where its range starts). Fusion's
 * `pointOnEdge`. False (and `last_error`), `out` untouched, for a null solid or `out` or an edge
 * out of range.
 *
 * # Safety
 * `solid` null or live; `out` null or one `CadaclysmBlacksmithEdgePoint`.
 */
bool cadaclysm_blacksmith_edge_inner_point(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t edge,
                                           struct CadaclysmBlacksmithEdgePoint *out);

/**
 * The width and height of the rectangle face `face` of `solid` would flatten to, into `out` (2
 * doubles): over the uv box the face's trims span, the longest of the `u`-isocurves at five
 * evenly spaced `v` is the width, the longest `v`-isocurve at five `u` the height. Rhino's
 * `GetSurfaceSize`. False (and `last_error`), `out` untouched, for a null solid or `out`, a face
 * out of range or one whose trims cannot be read.
 *
 * # Safety
 * `solid` null or live; `out` null or room for 2 doubles.
 */
bool cadaclysm_blacksmith_face_size(const struct CadaclysmBlacksmithSolid *solid,
                                    uint32_t face,
                                    double *out);

/**
 * How edge `edge` of `solid`'s two faces meet along it, at `samples` points (16 at fewest), into
 * `out` -- see `CadaclysmBlacksmithEdgeConvexity`. A sample within `angular_tolerance` of tangent
 * is smooth. False (and `last_error`), `out` untouched, for a null solid or `out`, an edge out of
 * range, a bad angular tolerance, or an edge whose faces' sides cannot be told.
 *
 * `angular_tolerance` 0 or NaN: the angle the solid declares, else the `tolerance.angular`
 * option, 1 degree.
 *
 * # Safety
 * `solid` null or live; `out` null or one `CadaclysmBlacksmithEdgeConvexity`.
 */
bool cadaclysm_blacksmith_edge_convexity(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t edge,
                                         double angular_tolerance,
                                         uint32_t samples,
                                         struct CadaclysmBlacksmithEdgeConvexity *out);

/**
 * The convexity kind (0 smooth, 1 convex, 2 concave, 3 mixed, 4 open) of every edge of `solid`,
 * in the edge list's order at 16 samples each, into `out` (room for
 * `cadaclysm_blacksmith_edge_count` `uint32_t`s). Fusion's `concaveEdges`/`convexEdges` are the
 * edges reading 2 and 1. False (and `last_error`), `out` untouched, for a null solid or `out`, a
 * bad angular tolerance, or an edge whose faces' sides cannot be told.
 *
 * `angular_tolerance` 0 or NaN: the angle the solid declares, else the `tolerance.angular`
 * option, 1 degree.
 *
 * # Safety
 * `solid` null or live; `out` null or room for `edge_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_edges_convexity(const struct CadaclysmBlacksmithSolid *solid,
                                          double angular_tolerance,
                                          uint32_t *out);

/**
 * Face `face` of `solid` and every face reached from it across edges whose faces meet smoothly
 * (`cadaclysm_blacksmith_edge_convexity` kind 0 at `angular_tolerance`), into `out`: breadth
 * first, the face first, then each face's new neighbours in ascending index. Fusion's
 * `tangentiallyConnectedFaces`. Returns how many faces were written (at least 1), or -1 on a
 * refusal (negative: test `< 0`), with `last_error` set and `out` untouched, for a null solid or
 * `out`, a face out of range, a bad angular tolerance, or an edge whose convexity cannot be read.
 *
 * `angular_tolerance` 0 or NaN: the angle the solid declares, else the `tolerance.angular`
 * option, 1 degree.
 *
 * # Safety
 * `solid` null or live; `out` null or room for `face_count` `uint32_t`s.
 */
int32_t cadaclysm_blacksmith_tangent_faces(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t face,
                                           double angular_tolerance,
                                           uint32_t *out);

/**
 * Edge `edge` of `solid` and every edge reached from it through vertices where two edges' curves
 * run on with the same tangent (their tangents away from the vertex opposite within
 * `angular_tolerance`), into `out`, in the order found (the edge first). Any curve kind; a whole
 * closed curve has no ends and chains to nothing. Fusion's `tangentiallyConnectedEdges`. Returns
 * how many edges were written (at least 1), or -1 on a refusal (negative: test `< 0`), with
 * `last_error` set and `out` untouched, for a null solid or `out`, an edge out of range or a bad
 * angular tolerance.
 *
 * `angular_tolerance` 0 or NaN: the angle the solid declares, else the `tolerance.angular`
 * option, 1 degree.
 *
 * # Safety
 * `solid` null or live; `out` null or room for `edge_count` `uint32_t`s.
 */
int32_t cadaclysm_blacksmith_tangent_edges(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t edge,
                                           double angular_tolerance,
                                           uint32_t *out);

/**
 * For every face of `solid`, the index of its group of faces joined smoothly (as
 * `cadaclysm_blacksmith_tangent_faces`), into `out` (room for `cadaclysm_blacksmith_face_count`
 * `uint32_t`s), the groups numbered in the order of their lowest face (face 0's group is 0).
 * Rhino's `GetTangentConnectedComponents`, as face groups. Returns the number of groups, or -1
 * on a refusal (negative: test `< 0`), with `last_error` set and `out` untouched, for a null
 * solid or `out`, a bad angular tolerance, or an edge whose convexity cannot be read.
 *
 * `angular_tolerance` 0 or NaN: the angle the solid declares, else the `tolerance.angular`
 * option, 1 degree.
 *
 * # Safety
 * `solid` null or live; `out` null or room for `face_count` `uint32_t`s.
 */
int32_t cadaclysm_blacksmith_tangent_face_groups(const struct CadaclysmBlacksmithSolid *solid,
                                                 double angular_tolerance,
                                                 uint32_t *out);

/**
 * The angle at `vertex` between the arms to `a` and to `b` (3 doubles each), in radians 0 to pi,
 * into `out`. False (and `last_error`), `out` untouched, for a null point or `out`, a non-finite
 * point, or an arm no longer than 1e-12 of the largest coordinate magnitude of the three.
 *
 * # Safety
 * `a`, `vertex`, `b` null or 3 doubles each; `out` null or one double.
 */
bool cadaclysm_blacksmith_angle_points(const double *a,
                                       const double *vertex,
                                       const double *b,
                                       double *out);

/**
 * The angle between entity `index_a` of `a` and `index_b` of `b` (the same solid may be passed
 * twice), into `out` -- see `CadaclysmBlacksmithAngle`. `kind_a`, `kind_b`: 0 a face, 1 an edge.
 * A planar face is read as its plane (outward normal); a cylinder's, cone's or revolved face as
 * its axis; a straight edge as its line (start to end); a circular edge as its circle's plane.
 * `at_a`, `at_b` are a face's or an edge's inner point, or for an axis its point nearest the
 * face's. Fusion's `measureAngle`. False (and `last_error`), `out` untouched, for a null solid
 * or `out`, a kind not 0 or 1, an index out of range, a face neither planar nor with an axis, or
 * an edge neither straight nor circular.
 *
 * # Safety
 * `a`, `b` null or live; `out` null or one `CadaclysmBlacksmithAngle`.
 */
bool cadaclysm_blacksmith_angle_between(const struct CadaclysmBlacksmithSolid *a,
                                        uint32_t kind_a,
                                        uint32_t index_a,
                                        const struct CadaclysmBlacksmithSolid *b,
                                        uint32_t kind_b,
                                        uint32_t index_b,
                                        struct CadaclysmBlacksmithAngle *out);

/**
 * The smallest radius of curvature over face `face` of `solid`, into `out` -- see
 * `CadaclysmBlacksmithMinimumRadius`. Planes, cylinders, cones, spheres and tori in closed form
 * where the minimising parameter is on the face; otherwise, and for every other surface, a grid
 * of `samples` steps each way (16 at fewest) over the face's trimmed uv box, the tightest
 * samples polished. Fusion's `MinimumRadiusAnalyses`. False (and `last_error`), `out`
 * untouched, for a null solid or `out`, a face out of range, trims that cannot be read, or a
 * face where no sample has a normal.
 *
 * # Safety
 * `solid` null or live; `out` null or one `CadaclysmBlacksmithMinimumRadius`.
 */
bool cadaclysm_blacksmith_face_minimum_radius(const struct CadaclysmBlacksmithSolid *solid,
                                              uint32_t face,
                                              uint32_t samples,
                                              struct CadaclysmBlacksmithMinimumRadius *out);

/**
 * `profile`'s area properties in its own plane, into `out` -- see
 * `CadaclysmBlacksmithAreaProperties`: the outer loop's region less its holes, whatever their
 * winding; lines and arcs in closed form, polynomial splines exactly, rational ones (conics,
 * weighted NURBS) adaptively to `accuracy` relative to the profile's size. Fusion's
 * `Profile.areaProperties`, Rhino's `AreaMassProperties` of closed planar curves. False (and
 * `last_error`), `out` untouched, for a null profile or `out`, an `accuracy` outside (0, 1), a
 * hole with holes of its own, or a segment that cannot be measured.
 *
 * `accuracy` 0 or NaN: 1e-9.
 *
 * # Safety
 * `profile` null or live; `out` null or one `CadaclysmBlacksmithAreaProperties`.
 */
bool cadaclysm_blacksmith_profile_area_properties(const struct CadaclysmBlacksmithProfile *profile,
                                                  double accuracy,
                                                  struct CadaclysmBlacksmithAreaProperties *out);

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
 * The nearest point of `solid`'s boundary to `p` (3 doubles), into `out` -- see
 * `CadaclysmBlacksmithPointFoot` for what the figures promise. Returns 1 with `out` filled; 0,
 * `out` untouched, where the nearest point is beyond `max_distance`; and -1 on a refusal
 * (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and
 * `out` untouched, for a null solid, `p` or `out`, a non-finite point, a negative
 * `max_distance`, a tolerance that is negative or infinite, or a body that meshes to nothing.
 *
 * `max_distance` NaN or +inf is no limit. Only a nearest point *beyond* it answers 0: one a
 * rounding error past it is not beyond, so `max_distance` 0 finds a point that lies on the
 * body and answers 0 for one off it.
 *
 * `tolerance` sizes the mesh search: a `refined` 0 answer is within `[d - 2/3 tolerance,
 * d + tolerance]` of the true distance `d`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * This meshes the body every call: for more than a few points build a
 * [`CadaclysmBlacksmithProjector`].
 *
 * # Safety
 * `solid` null or live; `p` null or readable for 3 doubles; `out` null or one
 * `CadaclysmBlacksmithPointFoot`.
 */
int32_t cadaclysm_blacksmith_closest_point(const struct CadaclysmBlacksmithSolid *solid,
                                           const double *p,
                                           double max_distance,
                                           double tolerance,
                                           struct CadaclysmBlacksmithPointFoot *out);

/**
 * A projector for `solid` at the absolute `tolerance` (positive and finite, or unset). Null (and
 * `last_error`) for a null `solid`, a tolerance that is negative or infinite, or a body that
 * meshes to nothing. Open bodies and sheets are accepted.
 *
 * `tolerance` sizes the mesh search: a `refined` 0 answer is within `[d - 2/3 tolerance,
 * d + tolerance]` of the true distance `d`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithProjector *cadaclysm_blacksmith_projector_new(const struct CadaclysmBlacksmithSolid *solid,
                                                                        double tolerance);

/**
 * The nearest point of the projector's body to `p` (3 doubles), into `out`, answered as
 * [`cadaclysm_blacksmith_closest_point`] answers it, `max_distance` included: 1 found, 0
 * (`out` untouched) beyond `max_distance`, and -1 on a refusal (negative: test `< 0`; the bits
 * of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null
 * `projector`, `p` or `out`, a non-finite point or a negative `max_distance`.
 *
 * # Safety
 * `projector` null or live; `p` null or readable for 3 doubles; `out` null or one
 * `CadaclysmBlacksmithPointFoot`. The handle wraps the kernel's projector in a mutex, so calls
 * from several threads on one projector are safe and serialise; build one projector per thread
 * to ask in parallel.
 */
int32_t cadaclysm_blacksmith_projector_closest_point(const struct CadaclysmBlacksmithProjector *projector,
                                                     const double *p,
                                                     double max_distance,
                                                     struct CadaclysmBlacksmithPointFoot *out);

/**
 * Release a projector. Null is a no-op.
 *
 * # Safety
 * `projector` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_projector_free(struct CadaclysmBlacksmithProjector *projector);

/**
 * The nearest point to `p` (3 doubles) of face `face` of `solid` alone, inside its trims or on
 * its boundary, into `out`: exact, no mesh, `refined` 1. Returns 1 with `out` filled, or -1 on
 * a refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error`
 * set and `out` untouched, for a null solid, `p` or `out`, a face out of range, a non-finite
 * point or a face that gives no point.
 *
 * # Safety
 * `solid` null or live; `p` null or readable for 3 doubles; `out` null or one
 * `CadaclysmBlacksmithPointFoot`.
 */
int32_t cadaclysm_blacksmith_face_closest_point(const struct CadaclysmBlacksmithSolid *solid,
                                                uint32_t face,
                                                const double *p,
                                                struct CadaclysmBlacksmithPointFoot *out);

/**
 * The nearest point to `p` (3 doubles) of edge `edge` -- a row of the list
 * `cadaclysm_blacksmith_edge` walks, the number `edge_length` and `fillet` take and a
 * `CadaclysmBlacksmithPointFoot`'s `edge` -- on its own curve over its range, as five doubles
 * into `out`: `t x y z distance`, `t` the parameter `edge_curve` and `edge_point_at_length` use.
 * Exact, no mesh. Returns 1, or -1 on a refusal (negative: test `< 0`; the bits of
 * `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null solid, `p`
 * or `out`, a row out of range, one with no exact curve, or a non-finite point.
 *
 * # Safety
 * `solid` null or live; `p` null or readable for 3 doubles; `out` null or room for 5 doubles.
 */
int32_t cadaclysm_blacksmith_edge_closest_point(const struct CadaclysmBlacksmithSolid *solid,
                                                uint32_t edge,
                                                const double *p,
                                                double *out);

/**
 * The nearest point of `curve` to `p` (3 doubles) over its whole domain, as five doubles into
 * `out`: `t x y z unique`, `unique` 1 where no other point of the curve is as near and 0 where
 * one is (a point on a circle's axis). Returns 1, or -1 on a refusal (negative: test `< 0`; the
 * bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null
 * curve, `p` or `out`, or a non-finite point.
 *
 * # Safety
 * `curve` null or live; `p` null or readable for 3 doubles; `out` null or room for 5 doubles.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_closest_point(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                       const double *p,
                                                       double *out);

/**
 * The nearest point of `curve` to `p` (3 doubles) over its whole domain, as five doubles into
 * `out` -- `t x y z unique`, as `cadaclysm_blacksmith_nurbs_curve_closest_point` answers them,
 * to the bit -- where it is within `max_distance`. Returns 1 with `out` filled; 0, `out`
 * untouched, where the nearest point is beyond `max_distance`; and -1 on a refusal (negative:
 * test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out`
 * untouched, for a null curve, `p` or `out`, a curve that is not valid, a non-finite point or
 * a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit. Only a nearest point *beyond* it answers 0: one a
 * rounding error past it is not beyond.
 *
 * # Safety
 * `curve` null or live; `p` null or readable for 3 doubles; `out` null or room for 5 doubles.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_closest_point_within(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                              const double *p,
                                                              double max_distance,
                                                              double *out);

/**
 * The closest points of curves `a` and `b`, into `out` (`t_a`/`point_a` on `a`) -- see
 * `CadaclysmBlacksmithCurvePair`. Returns 1 with `out` filled; 0, `out` untouched, where they
 * are farther apart than `max_distance`; and -1 on a refusal (negative: test `< 0`; the bits
 * of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null curve
 * or `out`, a curve that is not valid, or a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit; only a distance *beyond* it answers 0.
 *
 * # Safety
 * `a` and `b` null or live; `out` null or one `CadaclysmBlacksmithCurvePair`.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_closest_points(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                        const struct CadaclysmBlacksmithNurbsCurve *b,
                                                        double max_distance,
                                                        struct CadaclysmBlacksmithCurvePair *out);

/**
 * The nearest points of `curve` and `solid`'s boundary, into `out` -- see
 * `CadaclysmBlacksmithCurveBodyFoot` (read `body.edge` for the public edge number). Returns 1
 * with `out` filled; 0, `out` untouched, where the body is farther than `max_distance`; and -1
 * on a refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with
 * `last_error` set and `out` untouched, for a null solid, curve or `out`, a curve that is not
 * valid, a negative `max_distance`, a tolerance that is negative or infinite, a body that
 * meshes to nothing, or a curve too long for the tolerance.
 *
 * `max_distance` NaN or +inf is no limit; only a distance *beyond* it answers 0.
 *
 * `tolerance` sizes the march along the curve and the mesh search: a `body.refined` 0 answer
 * is within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * This meshes the body every call: for more than a few curves build a
 * [`CadaclysmBlacksmithProjector`] and ask
 * [`cadaclysm_blacksmith_projector_curve_closest_points`].
 *
 * # Safety
 * `solid` and `curve` null or live; `out` null or one `CadaclysmBlacksmithCurveBodyFoot`.
 */
int32_t cadaclysm_blacksmith_curve_closest_points(const struct CadaclysmBlacksmithSolid *solid,
                                                  const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                  double max_distance,
                                                  double tolerance,
                                                  struct CadaclysmBlacksmithCurveBodyFoot *out);

/**
 * The nearest points of `curve` and the projector's body, into `out`, answered as
 * [`cadaclysm_blacksmith_curve_closest_points`] answers them at the projector's tolerance,
 * `max_distance` included: 1 found, 0 (`out` untouched) beyond `max_distance`, and -1 on a
 * refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error`
 * set and `out` untouched, for a null `projector`, curve or `out`, a curve that is not valid,
 * a negative `max_distance`, or a curve too long for the tolerance.
 *
 * # Safety
 * `projector` and `curve` null or live; `out` null or one `CadaclysmBlacksmithCurveBodyFoot`.
 * The projector's lock is held for the whole curve query: other threads asking this projector
 * (points or curves) wait for it.
 */
int32_t cadaclysm_blacksmith_projector_curve_closest_points(const struct CadaclysmBlacksmithProjector *projector,
                                                            const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                            double max_distance,
                                                            struct CadaclysmBlacksmithCurveBodyFoot *out);

/**
 * The item of a set nearest to `curve`, into `out` -- see `CadaclysmBlacksmithNearestObject`.
 *
 * The set is `count` kinds, `kinds[i]` 0 a solid, 1 a curve, 2 a point, 3 a projector, 4 a
 * triangle mesh or 5 an untrimmed NURBS surface, each taking the next item of that kind's
 * array in order: `solids` (`n_solids` handles), `curves` (`n_curves`), `points` (3 doubles per
 * point, `n_points` points), `projectors` (`n_projectors`), `meshes` (`n_meshes`) and
 * `surfaces` (`n_surfaces`). The values 0 to 4 are unchanged from before surfaces joined the
 * set; a caller with no meshes passes `meshes` NULL and `n_meshes` 0, and one with no surfaces
 * `surfaces` NULL and `n_surfaces` 0. Each count must be how many `kinds` name. `which`
 * indexes `kinds`. An array whose count is 0 may be null; `count` 0 is an empty set, which
 * answers 0.
 *
 * Items are asked in order, each with the best distance so far as its limit, and once one
 * touches the curve no later item is asked; equal distances go to the earlier item. A mesh is
 * answered exactly, as `cadaclysm_blacksmith_triangle_mesh_curve_closest_points` answers it
 * (`answer_kind` 3), and a surface exactly, as
 * `cadaclysm_blacksmith_nurbs_surface_curve_closest_points` answers it (`answer_kind` 4).
 *
 * Returns 1 with `out` filled; 0, `out` untouched, where no item is within `max_distance`; and
 * -1 on a refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with
 * `last_error` set and `out` untouched, for a null curve or `out`, a null array behind a
 * non-zero count, a count that disagrees with `kinds` (`kinds name 2 solids, n_solids is 1`,
 * `kinds name 1 meshes, n_meshes is 0`, `kinds name 1 surfaces, n_surfaces is 0`), a kind out
 * of range, a null handle, an invalid curve
 * item or a non-finite point (each named `item <i>: ...`), an `n_points` too large to address,
 * a curve that is not valid, a negative `max_distance`, a tolerance that is
 * negative or infinite (with or without solids in the set), or a body's own refusal (one that
 * meshes to nothing, a curve too long for the tolerance), which does not name its item.
 *
 * `max_distance` NaN or +inf is no limit; only a distance *beyond* it answers 0.
 *
 * `tolerance` sizes each solid's march and mesh search: a `body.body.refined` 0 answer is
 * within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. A projector keeps its
 * own tolerance.
 *
 * `tolerance` 0 or NaN: each solid's own effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve` null or live; `kinds` null or `count` bytes; `solids`, `curves`, `projectors`,
 * `meshes` and `surfaces` null or their counts' handles, each null or live; `points` null or
 * `3 * n_points` doubles; `out` null or one `CadaclysmBlacksmithNearestObject`. Every projector
 * in the set has its lock held for the whole curve query (each once, however often it is
 * listed, in one order across calls): other threads asking those projectors wait for it.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_closest_object(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                        const uint8_t *kinds,
                                                        uint32_t count,
                                                        const struct CadaclysmBlacksmithSolid *const *solids,
                                                        uint32_t n_solids,
                                                        const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                        uint32_t n_curves,
                                                        const double *points,
                                                        uint32_t n_points,
                                                        const struct CadaclysmBlacksmithProjector *const *projectors,
                                                        uint32_t n_projectors,
                                                        const struct CadaclysmBlacksmithTriangleMesh *const *meshes,
                                                        uint32_t n_meshes,
                                                        const struct CadaclysmBlacksmithNurbsSurface *const *surfaces,
                                                        uint32_t n_surfaces,
                                                        double max_distance,
                                                        double tolerance,
                                                        struct CadaclysmBlacksmithNearestObject *out);

/**
 * The mesh of `positions` (`vertex_count` vertices, 3 doubles each) and `indices`
 * (`triangle_count` triangles, 3 vertex indices each, any winding); both are copied. Null (and
 * `last_error`, prefixed `triangle_mesh_new: `) for a null array behind a non-zero count, no
 * triangles, an index past the vertex count, or a coordinate that is not finite.
 *
 * # Safety
 * `positions` null or `3 * vertex_count` doubles; `indices` null or `3 * triangle_count`
 * `uint32_t`s. A count whose 3-fold does not fit the address space is refused by name.
 */
struct CadaclysmBlacksmithTriangleMesh *cadaclysm_blacksmith_triangle_mesh_new(const double *positions,
                                                                               uint32_t vertex_count,
                                                                               const uint32_t *indices,
                                                                               uint32_t triangle_count);

/**
 * The triangle mesh of `solid` that the measuring queries search: its **measuring**
 * tessellation, within a third of `tolerance` of the surface -- finer than the display mesh
 * [`cadaclysm_blacksmith_mesh`](crate::cadaclysm_blacksmith_mesh) gives at the same tolerance.
 * The answers against it are exact for the mesh, not for the body. Null (and `last_error`,
 * prefixed `solid_triangle_mesh: `) for a null solid, a tolerance that is negative or infinite,
 * or a body that meshes to nothing.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithTriangleMesh *cadaclysm_blacksmith_solid_triangle_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 double tolerance);

/**
 * Release a triangle mesh. Null is a no-op.
 *
 * # Safety
 * `mesh` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_triangle_mesh_free(struct CadaclysmBlacksmithTriangleMesh *mesh);

/**
 * How many vertices the mesh holds; 0 for a null `mesh`.
 *
 * # Safety
 * `mesh` null or live.
 */
uint32_t cadaclysm_blacksmith_triangle_mesh_vertex_count(const struct CadaclysmBlacksmithTriangleMesh *mesh);

/**
 * How many triangles the mesh holds; 0 for a null `mesh`.
 *
 * # Safety
 * `mesh` null or live.
 */
uint32_t cadaclysm_blacksmith_triangle_mesh_triangle_count(const struct CadaclysmBlacksmithTriangleMesh *mesh);

/**
 * The box of every vertex, into `out` as `min x, min y, min z, max x, max y, max z`. False
 * (and `last_error`, `out` untouched) for a null `mesh` or `out`.
 *
 * # Safety
 * `mesh` null or live; `out` null or room for 6 doubles.
 */
bool cadaclysm_blacksmith_triangle_mesh_bounds(const struct CadaclysmBlacksmithTriangleMesh *mesh,
                                               double *out);

/**
 * The nearest point of the mesh to `p` (3 doubles), into `out` -- see
 * `CadaclysmBlacksmithMeshPoint`: exact, the lower triangle where several share the point, its
 * unused `vertices` slots `UINT32_MAX`. Returns 1 with `out` filled; 0, `out` untouched, where
 * the nearest point is beyond `max_distance`; and -1 on a refusal (negative: test `< 0`; the
 * bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null
 * `mesh`, `p` or `out`, a point that is not finite, or a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit. Only a nearest point *beyond* it answers 0: one a
 * rounding error past it is not beyond, so `max_distance` 0 finds a point that lies on the
 * mesh.
 *
 * # Safety
 * `mesh` null or live; `p` null or readable for 3 doubles; `out` null or one
 * `CadaclysmBlacksmithMeshPoint`.
 */
int32_t cadaclysm_blacksmith_triangle_mesh_closest_point(const struct CadaclysmBlacksmithTriangleMesh *mesh,
                                                         const double *p,
                                                         double max_distance,
                                                         struct CadaclysmBlacksmithMeshPoint *out);

/**
 * The nearest points of `curve` and the mesh, into `out` -- see
 * `CadaclysmBlacksmithCurveMeshFoot`: exact, `crossing` 1 and `distance` 0 at the earliest
 * crossing in `t`, the lower triangle and then the lower `t` among equal distances. Returns 1
 * with `out` filled; 0, `out` untouched, where the mesh is farther than `max_distance`; and -1
 * on a refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with
 * `last_error` set and `out` untouched, for a null `mesh`, curve or `out`, a curve that is not
 * valid, or a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit; only a distance *beyond* it answers 0.
 *
 * # Safety
 * `mesh` and `curve` null or live; `out` null or one `CadaclysmBlacksmithCurveMeshFoot`.
 */
int32_t cadaclysm_blacksmith_triangle_mesh_curve_closest_points(const struct CadaclysmBlacksmithTriangleMesh *mesh,
                                                                const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                double max_distance,
                                                                struct CadaclysmBlacksmithCurveMeshFoot *out);

/**
 * The surface of the control net `points` (`n_u` rows of `n_v` points, three doubles each:
 * row `i`, point `j` at `3 * (i * n_v + j)`; rows run along `u`), of degrees `degree_u` and
 * `degree_v` (1 to 7 each), with `weights` (`n_u * n_v`, positive and finite; NULL for a plain
 * B-spline) and the full knot vectors `knots_u` (`n_knots_u = n_u + degree_u + 1` values,
 * finite, non-decreasing and clamped: the first and the last `degree_u + 1` equal) and
 * `knots_v` likewise (NULL for clamped and uniform over [0, 1]; the count is then not read).
 * Everything is copied. Null (and `last_error`, prefixed `nurbs_surface_new: `) for a null
 * `points` behind a non-zero count, a degree out of range, too few points for a degree, a
 * point that is not finite, a bad weight, knots of the wrong count, decreasing, not clamped or
 * leaving no domain, counts too large to address, or a surface the queries cannot search.
 *
 * # Safety
 * `points` null or `3 * n_u * n_v` doubles; `weights` null or `n_u * n_v` doubles; `knots_u`
 * null or `n_knots_u` doubles; `knots_v` null or `n_knots_v` doubles.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_new(const double *points,
                                                                               uint32_t n_u,
                                                                               uint32_t n_v,
                                                                               uint32_t degree_u,
                                                                               uint32_t degree_v,
                                                                               const double *weights,
                                                                               const double *knots_u,
                                                                               uint32_t n_knots_u,
                                                                               const double *knots_v,
                                                                               uint32_t n_knots_v);

/**
 * The surface of face `face` (its row in the solid's face table) of `solid`, its trims
 * ignored, as an exact NURBS: a NURBS face as it is (clamped if it came unclamped); a cylinder,
 * cone, sphere or torus in its exact rational form over a parameter range that covers the face
 * (never smaller, but for a rare holed tube face); a plane as the bilinear patch over the
 * rectangle its trims span. `(u, v)` are the NURBS's own parameters. Null (and `last_error`,
 * prefixed `solid_face_surface: `) for a null solid, a face out of range, a face with no exact
 * NURBS form, and a surface the queries cannot search.
 *
 * # Safety
 * `solid` null or live.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_solid_face_surface(const struct CadaclysmBlacksmithSolid *solid,
                                                                                uint32_t face);

/**
 * Release a surface. Null is a no-op.
 *
 * # Safety
 * `surface` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_nurbs_surface_free(struct CadaclysmBlacksmithNurbsSurface *surface);

/**
 * The degrees, into `out` as `degree_u, degree_v`. False (and `last_error`, `out` untouched)
 * for a null `surface` or `out`.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 2 `uint32_t`s.
 */
bool cadaclysm_blacksmith_nurbs_surface_degrees(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                uint32_t *out);

/**
 * The control-point counts, into `out` as `n_u, n_v`. False (and `last_error`, `out`
 * untouched) for a null `surface` or `out`.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 2 `uint32_t`s.
 */
bool cadaclysm_blacksmith_nurbs_surface_counts(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                               uint32_t *out);

/**
 * The parameter domain, into `out` as `u0, u1, v0, v1`. False (and `last_error`, `out`
 * untouched) for a null `surface` or `out`.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 4 doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_domain(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                               double *out);

/**
 * The point at `(u, v)`, into `out` (3 doubles). False (and `last_error`, prefixed
 * `nurbs_surface_point_at: `, `out` untouched) for a null `surface` or `out`, or a parameter
 * outside the domain or not finite.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 3 doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_point_at(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                 double u,
                                                 double v,
                                                 double *out);

/**
 * The unit normal at `(u, v)` (`dS/du x dS/dv`, normalised), into `out` (3 doubles). False
 * (and `last_error`, prefixed `nurbs_surface_normal_at: `, `out` untouched) for a null
 * `surface` or `out`, a parameter outside the domain or not finite, or a place where the
 * partials are parallel (a pole) -- exactly where a closest point's `normal` is zero.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 3 doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_normal_at(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                  double u,
                                                  double v,
                                                  double *out);

/**
 * The whole surface as an open one-face sheet. The sheet's face is the same surface
 * reparametrised over [0, 1] x [0, 1]: its face surface
 * ([`cadaclysm_blacksmith_solid_face_surface`]) has domain [0, 1]^2, not this one's. Null
 * (and `last_error`, prefixed `nurbs_surface_to_sheet: `) for a null `surface` or one the
 * sheet cannot be built from (a side that is not a curve, or no size).
 *
 * # Safety
 * `surface` null or live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_nurbs_surface_to_sheet(const struct CadaclysmBlacksmithNurbsSurface *surface);

/**
 * The nearest point of the surface to `p` (3 doubles), into `out` -- see
 * `CadaclysmBlacksmithSurfacePoint`: exact, the lower `u` and then the lower `v` among equal
 * distances. Returns 1 with `out` filled; 0, `out` untouched, where the nearest point is
 * beyond `max_distance`; and -1 on a refusal (negative: test `< 0`; the bits of
 * `CADACLYSM_BLACKSMITH_NONE`), with `last_error` set and `out` untouched, for a null
 * `surface`, `p` or `out`, a point that is not finite, or a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit. Only a nearest point *beyond* it answers 0: one a
 * rounding error past it is not beyond, so `max_distance` 0 finds a point that lies on the
 * surface.
 *
 * # Safety
 * `surface` null or live; `p` null or readable for 3 doubles; `out` null or one
 * `CadaclysmBlacksmithSurfacePoint`.
 */
int32_t cadaclysm_blacksmith_nurbs_surface_closest_point(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                         const double *p,
                                                         double max_distance,
                                                         struct CadaclysmBlacksmithSurfacePoint *out);

/**
 * The nearest points of `curve` and the surface, into `out` -- see
 * `CadaclysmBlacksmithCurveSurfaceFoot`: exact, `crossing` 1 and `distance` 0 at the earliest
 * crossing in `t`, the lower `u`, `v` and then `t` among equal distances. Returns 1 with `out`
 * filled; 0, `out` untouched, where the surface is farther than `max_distance`; and -1 on a
 * refusal (negative: test `< 0`; the bits of `CADACLYSM_BLACKSMITH_NONE`), with `last_error`
 * set and `out` untouched, for a null `surface`, curve or `out`, a curve that is not valid, or
 * a negative `max_distance`.
 *
 * `max_distance` NaN or +inf is no limit; only a distance *beyond* it answers 0.
 *
 * # Safety
 * `surface` and `curve` null or live; `out` null or one `CadaclysmBlacksmithCurveSurfaceFoot`.
 */
int32_t cadaclysm_blacksmith_nurbs_surface_curve_closest_points(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                double max_distance,
                                                                struct CadaclysmBlacksmithCurveSurfaceFoot *out);

/**
 * The control points into `xyz` (`3 * n_u * n_v` doubles, row `i` along `u`, point `j` at
 * `3 * (i * n_v + j)`, as `cadaclysm_blacksmith_nurbs_surface_new` takes them). False and
 * `last_error` for a null surface or `xyz`.
 *
 * # Safety
 * `surface` null or live; `xyz` null or room for `3 * n_u * n_v` doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_control_points(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                       double *xyz);

/**
 * The weights into `w` (`n_u * n_v` doubles, the control points' order; all 1 for a plain
 * B-spline). False and `last_error` for a null surface or `w`.
 *
 * # Safety
 * `surface` null or live; `w` null or room for `n_u * n_v` doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_weights(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                double *w);

/**
 * The full knot vector along `dir` (0 `u`, 1 `v`) into `k`: `n_u + degree_u + 1` doubles for
 * `u`, `n_v + degree_v + 1` for `v`. False and `last_error` for a null surface or `k`, or
 * another direction.
 *
 * # Safety
 * `surface` null or live; `k` null or room for the knot count.
 */
bool cadaclysm_blacksmith_nurbs_surface_knots(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                              uint32_t dir,
                                              double *k);

/**
 * The same surface raised `by` degrees along `dir` (0 `u`, 1 `v`; to at most 12) -- exactly
 * (Rhino's `IncreaseDegreeU/V`). Null and `last_error` (prefixed `nurbs_surface_elevated: `)
 * otherwise.
 *
 * # Safety
 * `surface` null or live.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_elevated(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                    uint32_t dir,
                                                                                    uint32_t by);

/**
 * The knot `t` inserted `times` times along `dir` (0 `u`, 1 `v`) -- the same surface, exactly.
 * Null and `last_error` (prefixed `nurbs_surface_knot_inserted: `) for a `t` not strictly
 * inside the domain, a `times` of 0, or a multiplicity past the degree.
 *
 * # Safety
 * `surface` null or live.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_knot_inserted(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                         uint32_t dir,
                                                                                         double t,
                                                                                         uint32_t times);

/**
 * All `count` knots of `knots` (non-decreasing, each strictly inside the domain, no
 * multiplicity past the degree) inserted along `dir` -- the same surface, exactly. Null and
 * `last_error` (prefixed `nurbs_surface_knots_refined: `) otherwise.
 *
 * # Safety
 * `surface` null or live; `knots` `count` readable doubles.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_knots_refined(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                         uint32_t dir,
                                                                                         const double *knots,
                                                                                         uint32_t count);

/**
 * Up to `times` copies of the inner knot `t` along `dir` removed, each only while every row of
 * the net stays within `tolerance` (an absolute length; 0 or NaN the net's effective
 * tolerance) of itself; how many went is written to
 * `removed` (when not NULL) -- 0, and an unchanged copy, where none could. Null and
 * `last_error` (prefixed `nurbs_surface_knot_removed: `) for a `t` that is not an inner knot
 * and a negative or infinite tolerance.
 *
 * # Safety
 * `surface` null or live; `removed` NULL or writable.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_knot_removed(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                        uint32_t dir,
                                                                                        double t,
                                                                                        uint32_t times,
                                                                                        double tolerance,
                                                                                        uint32_t *removed);

/**
 * The surface moved `distance` along its normal (Rhino's `Surface.Offset`), refitted within
 * `tolerance`: a plane offsets exactly (error 0). Null and `last_error` (prefixed
 * `nurbs_surface_offset: `) for a distance that is not finite, a surface with no normal
 * somewhere, or an offset that folds over (a curvature radius used up). The fit's bound on the
 * distance from the exact offset goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the effective tolerance.
 *
 * # Safety
 * `surface` null or live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_offset(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                  double distance,
                                                                                  double tolerance,
                                                                                  double *error_out);

/**
 * The surface continued `length` past one side (0 the `u` start, 1 the `u` end, 2 the `v`
 * start, 3 the `v` end; Rhino's `Surface.Extend`) along its own end polynomials --
 * curvature-continuous, every old `(u, v)` keeping its point, the domain grown on that side.
 * Null and `last_error` (prefixed `nurbs_surface_extended: `) for another side or a length that
 * is not positive and finite.
 *
 * # Safety
 * `surface` null or live.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_extended(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                                                    uint32_t side,
                                                                                    double length);

/**
 * `a` and `b` joined along a side they share into one surface (Rhino's `MergeSurfaces`;
 * OCCT's `GeomConvert` concatenates curves only): a side of each, any of the four either way
 * along, must be the same curve within `tolerance`; `b` is turned to continue `a` across it
 * and the nets joined, `a` keeping its parameters and the shared row of control points. Every
 * point of either input is a point of the result; knots at the joint are removed as far as it
 * allows, so two halves of one smooth surface come back as that surface. A side collapsed to a
 * point (a pole) is never the shared side. Null and `last_error` (prefixed
 * `nurbs_surface_merge: `) for no side shared, sides that meet only in part (a whole side of
 * each must meet), or a shared side whose control points or weights differ (parametrised
 * differently).
 *
 * `tolerance` 0 or NaN: the two nets' effective tolerance.
 *
 * # Safety
 * `a`, `b` null or live.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_merge(const struct CadaclysmBlacksmithNurbsSurface *a,
                                                                                 const struct CadaclysmBlacksmithNurbsSurface *b,
                                                                                 double tolerance);

/**
 * `count` surfaces evenly between `a` and `b` (Rhino's `CreateTweenSurfaces` on matched nets;
 * Fusion and OCCT have none), written to `out[i]` (owned: free each with
 * `cadaclysm_blacksmith_nurbs_surface_free`), surface `i` at the fraction
 * `(i + 1) / (count + 1)`. Both are reparametrised to `[0, 1]` each way and made compatible
 * exactly (degrees elevated, knots merged), and their homogeneous nets blended; `u` goes with
 * `u` and `v` with `v`, as given. `false` and `last_error` (prefixed `nurbs_surface_tween: `)
 * for a null surface or `out`, or a `count` of 0; nothing is written to `out` then.
 *
 * # Safety
 * `a`, `b` null or live; `out` holds `count` pointers.
 */
bool cadaclysm_blacksmith_nurbs_surface_tween(const struct CadaclysmBlacksmithNurbsSurface *a,
                                              const struct CadaclysmBlacksmithNurbsSurface *b,
                                              uint32_t count,
                                              struct CadaclysmBlacksmithNurbsSurface **out);

/**
 * The point and its partial derivatives to second order at `(u, v)` into `out` (18 doubles:
 * `S, dS/du, dS/dv, d2S/du2, d2S/dudv, d2S/dv2`, three each; Rhino's `Surface.Evaluate` to
 * order 2). False and `last_error` (prefixed `nurbs_surface_second_derivatives: `) for a null
 * surface or `out`, or a parameter outside the domain or not finite.
 *
 * # Safety
 * `surface` null or live; `out` null or room for 18 doubles.
 */
bool cadaclysm_blacksmith_nurbs_surface_second_derivatives(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                           double u,
                                                           double v,
                                                           double *out);

/**
 * The principal, Gaussian and mean curvatures and the principal directions at `(u, v)` into
 * `out` (Rhino's `Surface.CurvatureAt`), from the first and second fundamental forms. False and
 * `last_error` (prefixed `nurbs_surface_curvature: `) for a null surface or `out`, a parameter
 * outside the domain or not finite, and a place with no normal (a pole).
 *
 * # Safety
 * `surface` null or live; `out` null or one writable `CadaclysmBlacksmithSurfaceCurvature`.
 */
bool cadaclysm_blacksmith_nurbs_surface_curvature(const struct CadaclysmBlacksmithNurbsSurface *surface,
                                                  double u,
                                                  double v,
                                                  struct CadaclysmBlacksmithSurfaceCurvature *out);

/**
 * The bicubic Hermite surface through an `n_u` x `n_v` grid (Rhino's `HermiteSurface`): `u`
 * (`n_u >= 2`) and `v` (`n_v >= 2`) the grid's parameters, strictly rising; `points`, `du`,
 * `dv` and `twists` (each `3 * n_u * n_v` doubles, node `(i, j)` at `3 * (i * n_v + j)`) its
 * points, derivatives `dS/du` and `dS/dv`, and twists `d2S/dudv`. Each grid cell is the bicubic
 * Hermite patch of its corners; the surface is cubic both ways with a double knot at every
 * inner grid parameter (`C1` across), `2 n_u x 2 n_v` control points, over the grid's
 * parameters, through every point with the given derivatives. Null and `last_error` (prefixed
 * `nurbs_surface_hermite: `) for a grid under 2 x 2, parameters not strictly rising, null lists
 * and numbers not finite.
 *
 * # Safety
 * `u` `n_u` doubles; `v` `n_v` doubles; `points`, `du`, `dv`, `twists` `3 * n_u * n_v` doubles each.
 */
struct CadaclysmBlacksmithNurbsSurface *cadaclysm_blacksmith_nurbs_surface_hermite(const double *u,
                                                                                   uint32_t n_u,
                                                                                   const double *v,
                                                                                   uint32_t n_v,
                                                                                   const double *points,
                                                                                   const double *du,
                                                                                   const double *dv,
                                                                                   const double *twists);

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
 * The smoothest curve of `degree` (3 to 7) within `tolerance` of `count` points, through the
 * first and the last: least squares plus the curvature's derivative squared, weighed as heavily
 * as the tolerance allows -- where `cadaclysm_blacksmith_nurbs_curve_fit` follows the points'
 * noise, this spends the tolerance on a calm curvature comb. With `no_inflection`, the curvature
 * does not turn over between points `span_from` and `span_to` (point indices, fractions between
 * points; a NaN end is the curve's own end, so NaN, NaN is the whole curve), and the call is
 * refused where no such curve is within the tolerance. The largest distance from a point to the
 * curve is written to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `xyz` holds `3 * count` doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fair(const double *xyz,
                                                                            size_t count,
                                                                            uint32_t degree,
                                                                            double tolerance,
                                                                            bool no_inflection,
                                                                            double span_from,
                                                                            double span_to,
                                                                            double *error_out);

/**
 * `curve` faired: the smoothest curve of `degree` (3 to 7) within `tolerance` of it (read at
 * even parameters along it), from its start to its end, as
 * `cadaclysm_blacksmith_nurbs_curve_fair` makes one from points; `span_from` and `span_to` are
 * `curve`'s own parameters here. The largest distance found between the two curves is written
 * to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the curve's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve` live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_faired(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                              uint32_t degree,
                                                                              double tolerance,
                                                                              bool no_inflection,
                                                                              double span_from,
                                                                              double span_to,
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
 * `curve`, lying on face `face` of `solid` within `tolerance`, read back into the face's surface
 * parameters (Rhino's `Pullback`): a **uv curve** -- a curve in the z = 0 plane whose x is `u`
 * and y is `v` -- over `curve`'s own domain, its point at `t` paired with `curve`'s at `t`. The
 * face is its whole surface (its trims are not read). Exact where the curve runs along a
 * parameter line and for a curve in a plane; otherwise fitted. Across a periodic surface's seam
 * the uv curve runs on rather than jumping a period, and it starts inside the domain. Where the
 * curve ends at a pole (a sphere's, a cone's apex) the uv curve meets the pole line square;
 * where it passes over one, the uv curve gains a run along the pole line there, so past that
 * point its parameter no longer pairs with `curve`'s. Refused (NULL) where the curve stands off
 * the surface past `tolerance`, naming where and how far. The deviation reached goes to
 * `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `curve`, `solid` live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_pulled_back(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                   const struct CadaclysmBlacksmithSolid *solid,
                                                                                   uint32_t face,
                                                                                   double tolerance,
                                                                                   double *error_out);

/**
 * The uv curve `uv` (a curve in the z = 0 plane: x is `u`, y is `v`) carried out through face
 * `face`'s surface of `solid` (Rhino's `Pushup`): a 3D curve over `uv`'s domain within
 * `tolerance` of the surface's points along it. Exact on a plane and along a parameter line (the
 * surface's own isocurve: a circle, a ruling, a patch's isocurve); otherwise fitted. Refused
 * where `uv` is not in the z = 0 plane or leaves a patch's domain on an axis that does not wrap.
 * The deviation reached goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `uv`, `solid` live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_pushed_up(const struct CadaclysmBlacksmithNurbsCurve *uv,
                                                                                 const struct CadaclysmBlacksmithSolid *solid,
                                                                                 uint32_t face,
                                                                                 double tolerance,
                                                                                 double *error_out);

/**
 * `curve` carried onto face `face` of `solid` and fitted to the face's surface parameter it
 * crosses (Rhino's `FitCurveToSurface`). The curve is projected onto the face's surface along
 * `direction` (three doubles), or pulled -- each point to its nearest -- where `direction` is
 * NULL or zero; that trace must cross the face's parameter rectangle (the box its trims span in
 * its surface's parameters) from one side to the opposite one. The result is parametrised by
 * the parameter it crosses -- at `t` it is over `u = t` (or `v = t`), running with it rising --
 * on the surface's own knots in that direction plus the `knot_count` doubles `knots` (each
 * strictly inside the range), at the surface's degree there, at least 3: knot-compatible with
 * the surface's isocurves. Where it is farther than `tolerance` from the trace, knots are added
 * halfway along the spans still off; it is never refused for the tolerance alone. Refused where
 * the trace does not cross, turns back, or a knot lies outside the range. A bound on the
 * distance from the exact trace (the projection's, the read-back's and the fit's deviations
 * added) goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `curve`, `solid` live; `direction` three doubles or NULL; `knots` holds `knot_count` doubles;
 * `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fitted_to_face(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                      const struct CadaclysmBlacksmithSolid *solid,
                                                                                      uint32_t face,
                                                                                      const double *direction,
                                                                                      const double *knots,
                                                                                      size_t knot_count,
                                                                                      double tolerance,
                                                                                      double *error_out);

/**
 * `curve` moved `distance` in space, square to its tangent and to `direction` (three doubles;
 * Rhino's `OffsetCurve`): to the right of the run seen from the tip of `direction` for a positive
 * `distance`, to the left for a negative one. A line or an arc in a plane square to `direction`
 * offsets exactly (error 0); anything else is fitted within `tolerance`. Distance 0 is a copy.
 * Null and `last_error` (prefixed `nurbs_curve_offset: `) for a NULL or zero `direction`, a
 * distance that is not finite, a corner (a kink the offset would tear at), or an offset that
 * folds over (an arc's radius used up, a turn tighter than `distance`). The fit's bound on the
 * distance from the exact offset goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the effective tolerance.
 *
 * # Safety
 * `curve` null or live; `direction` NULL or three doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_offset(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                              double distance,
                                                                              const double *direction,
                                                                              double tolerance,
                                                                              double *error_out);

/**
 * `curve`, lying on the sheet `solid` (within ten times `tolerance`), moved `distance` along the
 * sheet's normal at each point -- off the sheet, the way its faces face for a positive
 * `distance`. Fitted within `tolerance`. Null and `last_error` (prefixed
 * `nurbs_curve_offset_normal_to_sheet: `) for a curve off the sheet, one crossing a crease (faces
 * whose normals differ by more than a degree), a distance that is not finite, or an offset that
 * folds over. The fit's bound on the distance from the exact offset goes to `error_out` when that
 * is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `curve`, `solid` null or live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_offset_normal_to_sheet(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                              const struct CadaclysmBlacksmithSolid *solid,
                                                                                              double distance,
                                                                                              double tolerance,
                                                                                              double *error_out);

/**
 * `curve`, lying on the sheet `solid` (within ten times `tolerance`), moved `distance` in the
 * sheet's tangent plane, square to the curve: along `N x C'` (the sheet's normal crossed with the
 * curve's tangent) for a positive `distance`. Fitted within `tolerance`. Null and `last_error`
 * (prefixed `nurbs_curve_offset_tangent_to_sheet: `) as for
 * [`cadaclysm_blacksmith_nurbs_curve_offset_normal_to_sheet`]. The fit's bound on the distance
 * from the exact offset goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `curve`, `solid` null or live; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_offset_tangent_to_sheet(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                               const struct CadaclysmBlacksmithSolid *solid,
                                                                                               double distance,
                                                                                               double tolerance,
                                                                                               double *error_out);

/**
 * A smooth curve through `count` points `xyz` lying on face `face` of `solid` (Rhino's
 * `InterpolatedCurveOnSurface`): each point's nearest foot on the face's surface -- a point
 * farther than `tolerance` from it is refused, naming its index -- interpolated in the surface's
 * parameters (cubic, chord-length) and carried out through the surface. `closed` runs back to
 * the first point, smooth across the join; a closed ring round a periodic surface (a cylinder)
 * closes. The deviation reached goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `solid` live; `xyz` holds `3 * count` doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_through_on_face(const struct CadaclysmBlacksmithSolid *solid,
                                                                                       uint32_t face,
                                                                                       const double *xyz,
                                                                                       size_t count,
                                                                                       bool closed,
                                                                                       double tolerance,
                                                                                       double *error_out);

/**
 * A smooth curve through `count` surface parameters `uv` (two doubles each: `u`, `v`) of face
 * `face` of `solid` (Rhino's `InterpolatedCurveOnSurfaceUV`): interpolated in the parameters
 * (cubic, chord-length) and carried out through the surface, within `tolerance`. `closed` runs
 * back to the first point; a ring whose last point is a whole period short of the first on a
 * periodic surface winds round it and closes. A ring winding both parameters is refused. The
 * deviation reached goes to `error_out` when that is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `solid` live; `uv` holds `2 * count` doubles; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_through_uv_on_face(const struct CadaclysmBlacksmithSolid *solid,
                                                                                          uint32_t face,
                                                                                          const double *uv,
                                                                                          size_t count,
                                                                                          bool closed,
                                                                                          double tolerance,
                                                                                          double *error_out);

/**
 * The shortest path on face `face`'s surface of `solid` from surface parameters `a` to `b` (two
 * doubles each: `u`, `v`; Rhino's `ShortPath`), within `tolerance`: a geodesic, the straight run
 * between them relaxed until its length settles, tried a period either way round a periodic
 * surface and the shortest kept. It is the shortest path among those starts -- the quadrics'
 * and a gentle patch's shortest path; a surface with a hill between the points may hide a shorter
 * way round. The face's trims are not read. The deviation reached goes to `error_out` when that
 * is not NULL.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `solid` live; `a`, `b` two doubles each; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_short_path_on_face(const struct CadaclysmBlacksmithSolid *solid,
                                                                                          uint32_t face,
                                                                                          const double *a,
                                                                                          const double *b,
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
 * Where the curve's curvature turns from one side to the other, in parameter order, as a list
 * of `At` (point, unit tangent, parameter; `error` zero): the points where `C' x C''` passes
 * through zero and comes back reversed. A straight stretch between two opposite bends is one
 * inflection; a knot where the curvature flips without passing through zero is one, at the knot.
 * An empty list is a curve that bends one way only -- what a test of a design line asks for.
 *
 * # Safety
 * `curve` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_inflections(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * How smoothly the curve runs through its own knots, into `out`: the largest turn of its tangent
 * and jump of its curvature vector, with where each is.
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithKnotContinuity`.
 */
bool cadaclysm_blacksmith_nurbs_curve_knot_continuity(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                      struct CadaclysmBlacksmithKnotContinuity *out);

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
 * How well the two faces of edge `edge` of `solid` (the index `cadaclysm_blacksmith_edge_curve`
 * takes) meet along it, into `out`: `samples` points along the edge (16 at fewest), each
 * projected onto both faces, and the largest gap between the two feet, angle between the faces'
 * normals (each turned the way its face faces: a square crease reads pi/2, a fold back near pi)
 * and difference of their normal curvatures square to the edge. Any two faces of one body, any
 * kind of surface: a NURBS face's curvature is exact, another's differenced at a ten-thousandth
 * of the edge's length. Refused for an edge that does not bound exactly two faces.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithContinuity`.
 */
bool cadaclysm_blacksmith_edge_continuity(const struct CadaclysmBlacksmithSolid *solid,
                                          uint32_t edge,
                                          uint32_t samples,
                                          struct CadaclysmBlacksmithContinuity *out);

/**
 * Face `face` of `solid` faired, as a sheet of its own: the smoothest surface within `tolerance`
 * of its NURBS surface -- least squares plus the third derivatives squared across it (a zebra's
 * ripple), weighed as heavily as the tolerance allows. Where a sheet lofted through traced
 * sections wobbles between them, this spends the tolerance on smoothness.
 *
 * `controls_u` and `controls_v` both 0 fair on the face's own net, its degree raised to `degree`
 * (3 to 7) and its spans split to a dozen at least each way: a kept side is then kept exactly.
 * Otherwise the fair is a uniform B-spline of `degree` with that many control points each way,
 * its kept sides within the tolerance. `keep` holds four ints, one per side (0 the face's `u = 0`
 * isocurve, 1 `u = 1`, 2 `v = 0`, 3 `v = 1`): -1 the side is free to move, 0 its position is
 * kept, 1 the tangent plane across it too, 2 the curvature across it too -- what
 * `cadaclysm_blacksmith_match_side` gave it with a neighbour. NULL keeps every side at 2.
 * `no_inflection` bit 1 holds the isocurves along `u` from turning their curvature over (each
 * bends to the side it bends to most), bit 2 those along `v`: the surface form of
 * `cadaclysm_blacksmith_nurbs_curve_fair`'s span, what turns a sheet lofted through wobbly
 * sections into a dome. The largest distance found between the two surfaces (both ways) is
 * written to `error_out` when that is not NULL. Refused where even the least smoothing -- held,
 * where asked -- is not within the tolerance.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `keep` four ints or NULL; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_surface_faired(const struct CadaclysmBlacksmithSolid *solid,
                                                                     uint32_t face,
                                                                     double tolerance,
                                                                     uint32_t degree,
                                                                     uint32_t controls_u,
                                                                     uint32_t controls_v,
                                                                     const int32_t *keep,
                                                                     uint32_t no_inflection,
                                                                     double *error_out);

/**
 * Where face `face` of `solid`'s Gaussian and mean curvature change sign, on a grid of `samples`
 * steps each way over its surface's domain (8 at fewest), into `out`. Any kind of surface: a
 * NURBS face's curvature is exact, another's differenced.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithCurvatureTurns`.
 */
bool cadaclysm_blacksmith_curvature_turns(const struct CadaclysmBlacksmithSolid *solid,
                                          uint32_t face,
                                          uint32_t samples,
                                          struct CadaclysmBlacksmithCurvatureTurns *out);

/**
 * The points `cadaclysm_blacksmith_curvature_turns` finds between the signs of face `face`'s
 * Gaussian curvature (`mean` false) or mean curvature (`mean` true), as a list of `At`: one at
 * every pair of neighbouring samples of opposite sign, on the line between them -- the point,
 * the face's unit normal there as `tangent`, the face's `u` there as `parameter` (`error`
 * zero). An empty list is a face whose curvature keeps one sign.
 *
 * # Safety
 * `solid` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_curvature_turn_points(const struct CadaclysmBlacksmithSolid *solid,
                                                                              uint32_t face,
                                                                              uint32_t samples,
                                                                              bool mean);

/**
 * The worst kink of the highlight lines crossing edge `edge` of `solid` (the index
 * `cadaclysm_blacksmith_edge_curve` takes), at `samples` points along it (16 at fewest), into
 * `out`. The highlight lines are those of straight light tubes parallel to the surface a body's
 * size away (its box's diagonal), every tube direction tried at every point: they run on through
 * an edge where the two faces' curvatures agree (G2) and kink where the curvature jumps -- a
 * fillet's seam with a flat face among them, where an isophote would read nothing on the flat
 * side. Beside `cadaclysm_blacksmith_edge_continuity`'s curvature jump, this is the number a
 * zebra shows. Refused for an edge that does not bound exactly two faces.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithHighlightKink`.
 */
bool cadaclysm_blacksmith_highlight_kink(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t edge,
                                         uint32_t samples,
                                         struct CadaclysmBlacksmithHighlightKink *out);

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
 * `curve` with the knot `t` (strictly inside the domain) inserted `times` times -- the same
 * curve, exactly (Boehm insertion; Rhino's `Knots.InsertKnot`). Null and `last_error`
 * (prefixed `nurbs_curve_knot_inserted: `) for a `t` outside the domain, a `times` of 0, or a
 * multiplicity past the degree.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_knot_inserted(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                     double t,
                                                                                     uint32_t times);

/**
 * `curve` with all `count` knots of `knots` inserted (non-decreasing, each strictly inside the
 * domain, no multiplicity past the degree) -- the same curve, exactly (knot refinement). Null
 * and `last_error` (prefixed `nurbs_curve_knots_refined: `) otherwise.
 *
 * # Safety
 * `curve` live; `knots` `count` readable doubles.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_knots_refined(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                     const double *knots,
                                                                                     uint32_t count);

/**
 * `curve` with up to `times` copies of its inner knot `t` removed (Rhino's `Knots.RemoveKnots`),
 * each only while the curve stays within `tolerance` of itself; how many went is written to
 * `removed` (when not NULL) -- 0, and an unchanged copy, where none could go. `tolerance` 0 or
 * NaN: the curve's effective tolerance. Null and `last_error` (prefixed
 * `nurbs_curve_knot_removed: `) for a `t` that is not an inner knot and a negative or infinite
 * tolerance.
 *
 * # Safety
 * `curve` live; `removed` NULL or writable.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_knot_removed(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                    double t,
                                                                                    uint32_t times,
                                                                                    double tolerance,
                                                                                    uint32_t *removed);

/**
 * `count` curves made compatible (Rhino's `MakeCompatible`): each reparametrised to `[0, 1]`,
 * raised to the highest degree among them and refined with every other's knots, so all share
 * one degree, one knot vector and one control-point count -- each still the same point set.
 * Rational curves stay exact. Written to `out[i]` (owned: free each). `false` and `last_error`
 * (prefixed `nurbs_curve_compatible: `) for no curves, a null curve or `out`; nothing is
 * written then.
 *
 * # Safety
 * `curves` holds `count` live curves; `out` holds `count` pointers.
 */
bool cadaclysm_blacksmith_nurbs_curve_compatible(const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                 size_t count,
                                                 struct CadaclysmBlacksmithNurbsCurve **out);

/**
 * `curve` over the domain `[lo, hi]` (Rhino's `Reparameterize` / setting `Domain`): the same
 * points, the parameter mapped affinely. Null and `last_error` for `lo >= hi` or a bound that
 * is not finite.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_reparametrized(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                      double lo,
                                                                                      double hi);

/**
 * `curve`'s control points and weights over evenly spaced knots on its domain (Rhino's
 * `MakeUniform`): clamped where it was clamped, a periodic curve kept periodic. The shape moves
 * unless the knots were uniform already.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_uniform(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * `curve` with every weight 1 and its control points where they were (Rhino's
 * `MakeNonRational`): exact where the weights were all equal, otherwise a plain B-spline
 * through the same control polygon. (Every curve here is already a NURBS, so Rhino's
 * `MakeRational` has nothing to do.)
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_non_rational(const struct CadaclysmBlacksmithNurbsCurve *curve);

/**
 * The Greville abscissae (each control point's parameter, the mean of the `degree` knots
 * after its first) into `params` and the curve's points there into `xyz`, one per control
 * point (`control_count` doubles and `3 * control_count` doubles); either may be NULL to skip
 * it. False and `last_error` for a null curve.
 *
 * # Safety
 * `curve` live; `params` NULL or room for `control_count` doubles; `xyz` NULL or room for
 * `3 * control_count` doubles.
 */
bool cadaclysm_blacksmith_nurbs_curve_greville(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                               double *params,
                                               double *xyz);

/**
 * A periodic curve (seamless, `C^(degree-1)` all round) of the same degree from `curve`
 * (Rhino's `CreatePeriodicCurve`); a closed curve's repeated last control point is dropped
 * first, and a curve already periodic comes back as it is. `smooth` false keeps the control
 * points and weights and rewrites only the knots: the polygon wrapped over uniform knots on
 * `[0, m]` for `m` points (the curve no longer reaches the old ends). `smooth` true keeps
 * close to the curve instead: a plain periodic curve through its Greville points, on `[0, 1]`
 * by chord length. Null and `last_error` (prefixed `nurbs_curve_periodic: `) for fewer than
 * `degree + 1` distinct control points.
 *
 * # Safety
 * `curve` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_periodic(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                bool smooth);

/**
 * The curve halfway between `a` and `b` (Rhino's `CreateMeanCurve`): `b` lined up with `a`
 * first (turned, a closed one's seam moved), the two made compatible exactly and averaged in
 * homogeneous coordinates -- two arcs about one centre give the arc of the mean radius. The
 * matching tween at 1/2. `tolerance` 0 or NaN: the curves' effective tolerance (how far apart
 * a curve's ends may be and still close it). Null and `last_error` (prefixed
 * `nurbs_curve_mean: `) for one curve closed and the other open.
 *
 * # Safety
 * `a`, `b` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_mean(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                                            const struct CadaclysmBlacksmithNurbsCurve *b,
                                                                            double tolerance);

/**
 * `b` lined up with `a`: an open `b` turned where its ends lie crosswise to `a`'s, a closed one
 * turned where it runs the other way round and its seam moved to the point that lies, from its
 * centre, the way `a`'s start lies from `a`'s -- the same point set either way. `b` as it is
 * where one is closed and the other open. `tolerance` 0 or NaN: the curves' effective
 * tolerance (for closing).
 *
 * # Safety
 * `a`, `b` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_lined_up(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                                                const struct CadaclysmBlacksmithNurbsCurve *b,
                                                                                double tolerance);

/**
 * Whether `b` runs the same way as `a` (Rhino's `DoDirectionsMatch`): two closed curves going
 * round the same way (their area vectors on one side), otherwise `b`'s ends lying along `a`'s
 * rather than crosswise -- exactly where `cadaclysm_blacksmith_nurbs_curve_lined_up` would not
 * turn `b`. 1 yes, 0 no, -1 and `last_error` for a null curve, a curve with no domain, or a
 * closed curve with no area. `tolerance` as `lined_up`'s.
 *
 * # Safety
 * `a`, `b` live.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_directions_match(const struct CadaclysmBlacksmithNurbsCurve *a,
                                                          const struct CadaclysmBlacksmithNurbsCurve *b,
                                                          double tolerance);

/**
 * Which conic `curve` is, read from its points within `tolerance` (Rhino's
 * `GetConicSectionType`): `CADACLYSM_BLACKSMITH_CONIC_NONE` (0) for a curve that is not one
 * (straight, two lines through a corner, not planar, or off every conic by more than
 * `tolerance`), `_CIRCLE` (1), `_ELLIPSE` (2), `_HYPERBOLA` (3) or `_PARABOLA` (4). Any exact
 * form reads the same: a circle elevated to degree 5 is a circle. `tolerance` 0 or NaN: the
 * curve's effective tolerance. -1 and `last_error` for a null curve or a negative tolerance.
 *
 * # Safety
 * `curve` live.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_conic_type(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                    double tolerance);

/**
 * How many curves `list` holds; 0 (and `last_error`) for a null list.
 *
 * # Safety
 * `list` live or null.
 */
uint32_t cadaclysm_blacksmith_curve_list_count(const struct CadaclysmBlacksmithCurveList *list);

/**
 * A copy of curve `i` of `list`, owned by the caller (free it with
 * `cadaclysm_blacksmith_nurbs_curve_free`). Null (and `last_error`) for a null list or `i`
 * past the count.
 *
 * # Safety
 * `list` live or null.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_curve_list_curve(const struct CadaclysmBlacksmithCurveList *list,
                                                                            uint32_t i);

/**
 * Curve `i`'s facts into `out`. `false` (and `last_error`) for a null list or `out`, or `i`
 * past the count.
 *
 * # Safety
 * `list` live or null; `out` one `CadaclysmBlacksmithCurveInfo` or null.
 */
bool cadaclysm_blacksmith_curve_list_info(const struct CadaclysmBlacksmithCurveList *list,
                                          uint32_t i,
                                          struct CadaclysmBlacksmithCurveInfo *out);

/**
 * Release `list`; null is a no-op.
 *
 * # Safety
 * `list` from one of the calls above, not freed before.
 */
void cadaclysm_blacksmith_curve_list_free(struct CadaclysmBlacksmithCurveList *list);

/**
 * A helix or spiral as a curve (Rhino's `NurbsCurve.CreateSpiral`): about `axis` (a point on it
 * and its direction, six doubles; the direction need not be unit) from `start`, turning the
 * right-hand way about the direction and climbing `pitch` along it each turn (negative climbs
 * the other way, 0 is flat) for `turns` turns, its radius running linearly with the angle from
 * `start`'s distance from the axis to `end_radius` -- NaN or negative: the same, a helix. A
 * start on the axis takes revolve's reference direction. A C2 quintic, 16 spans a turn,
 * through the exact spiral at every span end and over the angle in radians; its largest
 * distance from the exact spiral (about `8e-8` of the radius on a helix) goes to `error_out`
 * when that is not NULL. Null (and `last_error`) for an axis direction zero or not finite,
 * `turns` not positive and finite, `pitch` not finite, both radii zero.
 *
 * # Safety
 * `axis` six doubles; `start` three; `error_out` one double or NULL.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_spiral(const double *axis,
                                                                              const double *start,
                                                                              double pitch,
                                                                              double turns,
                                                                              double end_radius,
                                                                              double *error_out);

/**
 * The length of `curve` over `[t0, t1]` of its parameter (Rhino's `GetLength(subdomain)`) to a
 * relative `accuracy` (0 or less: the default) into `out`. Refused for a range running
 * backwards or outside the domain.
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithLength`.
 */
bool cadaclysm_blacksmith_nurbs_curve_length_between(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                     double t0,
                                                     double t1,
                                                     double accuracy,
                                                     struct CadaclysmBlacksmithLength *out);

/**
 * The point at the fraction `f` of `curve`'s length, `f` in `[0, 1]` (Rhino's
 * `PointAtNormalizedLength`; the `At`'s `parameter` is `NormalizedLengthParameter`'s answer)
 * into `out` (`segment` NONE). 0 is the start and 1 the end exactly.
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithAt`.
 */
bool cadaclysm_blacksmith_nurbs_curve_point_at_normalized_length(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                 double f,
                                                                 double accuracy,
                                                                 struct CadaclysmBlacksmithAt *out);

/**
 * The points at each of the `n` fractions `f` of `curve`'s length, in the order given, over one
 * measure of it (Rhino's `NormalizedLengthParameters`).
 *
 * # Safety
 * `curve` live; `f` holds `n` doubles. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_points_at_normalized_lengths(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                                 const double *f,
                                                                                                 uint32_t n,
                                                                                                 double accuracy);

/**
 * Points along `curve` each `distance` in a straight line from the one before (Rhino's
 * `DivideEquidistant`): the first the curve's start, each next the first point further on
 * that is `distance` from the last, until none is; a closed curve does not wrap. Each
 * sample's `error` is how far its chord is from `distance`.
 *
 * # Safety
 * `curve` live. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_equidistant(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                       double distance);

/**
 * Where `curve` crosses the planes square to `to - from` through `from` and every `interval`
 * on towards `to` (Rhino's `DivideAsContour`), in the curve's parameter order; a plane the
 * curve lies in gives none. Each sample's `error` is its distance from its plane.
 *
 * # Safety
 * `curve` live; `from`, `to` three doubles. Free the list with `cadaclysm_blacksmith_samples_free`.
 */
struct CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_as_contour(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                                                      const double *from,
                                                                                      const double *to,
                                                                                      double interval);

/**
 * `curve`'s length mass properties to a relative `accuracy` (0 or less: the default) into
 * `out`: see [`CadaclysmBlacksmithLengthMass`].
 *
 * # Safety
 * `curve` live; `out` one `CadaclysmBlacksmithLengthMass`.
 */
bool cadaclysm_blacksmith_nurbs_curve_mass(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                           double accuracy,
                                           struct CadaclysmBlacksmithLengthMass *out);

/**
 * The pieces of face `face`'s isocurve that lie inside its trims (Rhino's
 * `TrimAwareIsoCurve`), in order along it: along `u` at `v = at` when `along_u`, else along
 * `v` at `u = at`. Exact on every surface kind (a sampled profile's falls back to a fit at
 * `tolerance`); each piece's ends are polished onto the edges they meet, and its `error` is
 * the larger of its fit error and those ends' distance from their edges. A periodic seam is
 * crossed in one piece. An `at` the face never reaches gives an empty list.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance.
 *
 * # Safety
 * `solid` live. Free the list with `cadaclysm_blacksmith_curve_list_free`.
 */
struct CadaclysmBlacksmithCurveList *cadaclysm_blacksmith_nurbs_curve_face_isocurves(const struct CadaclysmBlacksmithSolid *solid,
                                                                                     uint32_t face,
                                                                                     bool along_u,
                                                                                     double at,
                                                                                     double tolerance);

/**
 * The intervals of the swept parameter along which face `face`'s isocurve lies inside its trims
 * (Rhino's `TrimAwareIsoIntervals`), ascending, as `(start, end)` pairs: the count of pairs is
 * returned and `min(count, capacity)` pairs written to `out` (`2 * capacity` doubles; NULL with
 * a capacity of 0 asks for the count alone). 0 (and `last_error`) for a null solid, a face past
 * the end, an `at` not finite.
 *
 * # Safety
 * `solid` live; `out` room for `2 * capacity` doubles, or NULL with `capacity` 0.
 */
uint32_t cadaclysm_blacksmith_face_iso_intervals(const struct CadaclysmBlacksmithSolid *solid,
                                                 uint32_t face,
                                                 bool along_u,
                                                 double at,
                                                 double *out,
                                                 uint32_t capacity);

/**
 * Whether `curve` runs along one of face `face`'s isocurves (Rhino's `IsIsoparametric`): 1
 * along `u` (`v` held, its value to `at_out`), 2 along `v` (`u` held), 0 neither or not on the
 * face, -1 (and `last_error`) refused. Read back into the face's parameters at `tolerance`, the
 * curve is an isocurve where its parameter spread across the held direction is within
 * `tolerance` in space.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance.
 *
 * # Safety
 * `curve`, `solid` live; `at_out` one double or NULL.
 */
int32_t cadaclysm_blacksmith_nurbs_curve_is_isoparametric(const struct CadaclysmBlacksmithNurbsCurve *curve,
                                                          const struct CadaclysmBlacksmithSolid *solid,
                                                          uint32_t face,
                                                          double tolerance,
                                                          double *at_out);

/**
 * `solid` cut by the plane through `origin` square to `normal`, as curves in space (Rhino's
 * `Intersection.BrepPlane`): each closed section loop one closed curve, an open sheet's
 * crossing one open curve. A crossing on a line, circle, ellipse or NURBS is that curve
 * exactly; any other a cubic fitted at `tolerance` (its `error` says how far). A face lying in
 * the plane gives its own edges, exactly, as the section there. A plane missing the solid gives
 * an empty list.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance.
 *
 * # Safety
 * `solid` live; `origin`, `normal` three doubles. Free the list with `cadaclysm_blacksmith_curve_list_free`.
 */
struct CadaclysmBlacksmithCurveList *cadaclysm_blacksmith_solid_section_curves(const struct CadaclysmBlacksmithSolid *solid,
                                                                               const double *origin,
                                                                               const double *normal,
                                                                               double tolerance);

/**
 * `solid` cut by the planes square to `to - from` through `from` and every `interval` on
 * towards `to` (Rhino's `Brep.CreateContourCurves`), as `cadaclysm_blacksmith_solid_section_curves`
 * cuts by one: every plane's curves in plane order, each one's `plane` its index. Refused for
 * `from` and `to` the same point, an interval not positive and finite, more than 10,000 planes.
 *
 * `tolerance` 0 or NaN: the solid's effective tolerance.
 *
 * # Safety
 * `solid` live; `from`, `to` three doubles. Free the list with `cadaclysm_blacksmith_curve_list_free`.
 */
struct CadaclysmBlacksmithCurveList *cadaclysm_blacksmith_solid_contour_curves(const struct CadaclysmBlacksmithSolid *solid,
                                                                               const double *from,
                                                                               const double *to,
                                                                               double interval,
                                                                               double tolerance);

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
 * `half` and its reflection across `plane` joined into one symmetric body -- half a car, a hull
 * or a bottle modelled once and mirrored, with no crease on the plane. `plane` is a frame
 * (twelve doubles: origin, x, y, z), its z the plane's normal. With `snap` above 0, every NURBS
 * face of the half that is its whole surface and has a side whose control points all lie within
 * `snap` of the plane is squared to it first: that side pulled onto the plane and the next row
 * of control points stood straight off it along the normal, keeping its distance from the
 * plane, so the surface crosses the plane at 90 degrees and meets its mirror tangent and
 * curvature continuous; nothing past that row moves. `snap` 0 mirrors the half as it is. The
 * half and its mirror are then sewn within `tolerance`, the half's faces first. `report_out`,
 * when not NULL, gets seven doubles: the seam edges (one face from each half), the faces
 * squared, the furthest a control point moved, the seam's worst gap, angle between the faces'
 * normals (radians) and difference of their normal curvatures across it, and the naked edges
 * left on the body. Refused for a half lying on both sides of the plane, no edge of it on the
 * plane (none sewn to its mirror), and a face that cannot be squared: its next row on the plane
 * or past it, or rational with weights across the side not in one ratio.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `half` a live handle; `plane` twelve doubles; `report_out` seven doubles or NULL.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror_join(const struct CadaclysmBlacksmithSolid *half,
                                                                  const double *plane,
                                                                  double snap,
                                                                  double tolerance,
                                                                  double *report_out);

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
 * This library's build, as JSON: `{"branch": "master", "commit": "7e4b5058e", "date":
 * "2026-11-14", "time": "2026-11-14T10:22:31Z", "version": "0.14.2"}` -- the version, the
 * commit and branch it was built from (`"unknown"` built from no checkout), when (a release
 * pins its date), and the build date licenses compare. What an app shows as the cadaclysm it
 * runs on. Static; never freed.
 */
const char *cadaclysm_blacksmith_build(void);

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
 * The two faces' outward normals at the ends of each exact edge of
 * [`cadaclysm_blacksmith_gpu_surfaces`] at the same `tolerance`: `count` equals that record's
 * Bezier count (`edges_len / 16`), and Bezier `i`'s are `normals[12 * i .. 12 * i + 12]` --
 * the face of the trim it was traced from at its first and its last point, then the other
 * face along the same edge at the same two, `x, y, z` each, unit length; zeros for a face
 * the edge lacks or a normal that could not be found, and zeros throughout for a body that
 * is not closed (a sheet), whose faces turned away hide nothing. What a viewer
 * culls an exact edge by: on a closed body a point whose two faces both turn away from the
 * eye is hidden. A bad tolerance or argument: `count` 0, `normals` NULL, with `last_error`.
 * Same cache and lifetime rule as the mesh.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithEdgeNormals cadaclysm_blacksmith_gpu_edge_normals(const struct CadaclysmBlacksmithSolid *solid,
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
 * [`cadaclysm_blacksmith_assembly_3dm_bytes`], [`cadaclysm_blacksmith_mesh_file`](crate::cadaclysm_blacksmith_mesh_file),
 * [`cadaclysm_bim_sheet_pdf`](crate::cadaclysm_bim_sheet_pdf), [`cadaclysm_bim_sheets_pdf`](crate::cadaclysm_bim_sheets_pdf)). Null is
 * a no-op. `len` must be the
 * length that same call wrote through its own `len` -- the bytes carry no NUL or
 * length of their own to read it back from.
 *
 * # Safety
 * `bytes` null, or exactly what one of those calls returned and not yet freed, with
 * `len` that call's own out-written length.
 */
void cadaclysm_blacksmith_bytes_free(uint8_t *bytes,
                                     size_t len);

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
 * An empty page in `units`, the DXF unit codes: 0 unitless, 1 inches, 2 feet, 4
 * millimetres, 5 centimetres, 6 metres. Null and `last_error` for any other code.
 */
struct CadaclysmBlacksmithPage *cadaclysm_blacksmith_page_new(uint32_t units);

/**
 * `hlr`'s lines on the page, a view point `p` landing at `(x, y) + scale * p`: each line
 * written as the entities that draw it best -- lines, circular arcs and circles, elliptical
 * arcs, splines -- within the view's tolerance on the page, on the view's layers (see the
 * page's description). `false` and `last_error` for a null argument, `x` or `y` not
 * finite, a scale not positive and finite.
 *
 * # Safety
 * `page` null or live; `hlr` null or live.
 */
bool cadaclysm_blacksmith_page_add_view(struct CadaclysmBlacksmithPage *page,
                                        const struct CadaclysmBlacksmithHlr *hlr,
                                        double x,
                                        double y,
                                        double scale);

/**
 * `profile`'s outline and holes on layer `layer` (null: `0`), moved by (`x`, `y`): a loop
 * of lines and arcs as one closed polyline with bulges, any other loop as one entity a
 * side. A coloured profile draws in its colour. `false` and `last_error` for a null page
 * or profile, `x` or `y` not finite, a layer name that is empty, longer than 255
 * characters or holds one of `<>/\":;?*|=` or a control character.
 *
 * # Safety
 * `page` null or live; `profile` null or live; `layer` null or NUL-terminated.
 */
bool cadaclysm_blacksmith_page_add_profile(struct CadaclysmBlacksmithPage *page,
                                           const struct CadaclysmBlacksmithProfile *profile,
                                           const char *layer,
                                           double x,
                                           double y);

/**
 * `profile` hatched -- its outline filled, its holes left out -- on layer `layer` (null:
 * `hatch`), moved by (`x`, `y`). `pattern` is `SOLID`, `ANSI31` (lines at 45 degrees),
 * `ANSI37` (crossed), or `ANSI32` / `STEEL` (paired lines), any case; `angle` turns it,
 * radians counter-clockwise; `scale` multiplies its spacing. `false` and `last_error` for
 * a null argument, an unknown pattern, a scale not positive and finite, a number not
 * finite, a bad layer name (as [`cadaclysm_blacksmith_page_add_profile`]).
 *
 * # Safety
 * `page`, `profile` null or live; `layer` null or NUL-terminated; `pattern`
 * NUL-terminated.
 */
bool cadaclysm_blacksmith_page_add_hatch(struct CadaclysmBlacksmithPage *page,
                                         const struct CadaclysmBlacksmithProfile *profile,
                                         const char *layer,
                                         const char *pattern,
                                         double angle,
                                         double scale,
                                         double x,
                                         double y);

/**
 * One line of `text` (UTF-8) on layer `layer` (null: `text`) at (`x`, `y`), `height`
 * page units tall, turned `angle` radians counter-clockwise. `halign` is `left`,
 * `center` or `right` (null: left) and `valign` `baseline`, `bottom`, `middle` or `top`
 * (null: baseline): where (`x`, `y`) sits on the text. `false` and `last_error` for a null
 * page or text, a line break or control character in the text, a height not positive and
 * finite, a number not finite, an alignment not one of those words, a bad layer name.
 *
 * # Safety
 * `page` null or live; `text` NUL-terminated; `layer`, `halign`, `valign` null or
 * NUL-terminated.
 */
bool cadaclysm_blacksmith_page_add_text(struct CadaclysmBlacksmithPage *page,
                                        const char *text,
                                        const char *layer,
                                        double x,
                                        double y,
                                        double height,
                                        double angle,
                                        const char *halign,
                                        const char *valign);

/**
 * How many entities the page holds. 0 and `last_error` for a null page.
 *
 * # Safety
 * `page` null or live.
 */
uint32_t cadaclysm_blacksmith_page_entity_count(const struct CadaclysmBlacksmithPage *page);

/**
 * The page as an SVG document: one group per layer, dashes from the linetype, arcs as SVG
 * arcs, splines as cubic paths, hatches as filled paths or clipped line families. Owned:
 * release it with `cadaclysm_blacksmith_string_free`. Null and `last_error` for a null
 * page.
 *
 * # Safety
 * `page` null or live.
 */
char *cadaclysm_blacksmith_page_svg_text(const struct CadaclysmBlacksmithPage *page);

/**
 * The page as DXF R2000 (`AC1015`) text: its layers with their linetypes and pens, each
 * entity as the DXF entity of its kind, the same bytes for the same page. Owned: release
 * it with `cadaclysm_blacksmith_string_free`. Null and `last_error` for a null page.
 *
 * # Safety
 * `page` null or live.
 */
char *cadaclysm_blacksmith_page_dxf_text(const struct CadaclysmBlacksmithPage *page);

/**
 * Release a page. Null is a no-op.
 *
 * # Safety
 * `page` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_page_free(struct CadaclysmBlacksmithPage *page);

/**
 * A DXF file's closed loops as profiles: its lines, arcs, circles, ellipses, polylines
 * (with bulges) and splines -- blocks inserted where they are placed -- chained end to end
 * within `tolerance` into closed loops, each hole nested in the loop around it, outer loops
 * counter-clockwise and holes clockwise. Text, hatches and the entities a profile cannot
 * hold are skipped. `tolerance` 0 or NaN: the effective tolerance over the drawing's
 * extents. Read the list with `cadaclysm_blacksmith_profile_list_count` / `_get`; free it
 * with `cadaclysm_blacksmith_profile_list_free`. Null and `last_error` for null or
 * non-UTF-8 text, text that is not DXF (naming the line it stopped at), a tolerance
 * negative or infinite.
 *
 * # Safety
 * `text` null or NUL-terminated.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_dxf_profiles(const char *text,
                                                                         double tolerance);

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
 * `profile` with its corners rounded by `radius`, as a new profile: both
 * segments cut back -- lines, arcs and splines alike, each staying the curve it
 * was -- and an exact tangent arc put between them. A corner the two run
 * straight on through is no corner. `corners` null rounds every corner, the
 * holes' too; otherwise its `count` indices pick the corners of the boundary to
 * round -- corner `k` is where segment `k` ends -- and a picked corner that runs
 * straight on is refused. `open` treats the profile as an open chain,
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
 * A profile from piece definitions: `json` a list in `curve.polycurve`'s `pieces` grammar
 * (`{"kind": "line", "x0", "y0", "x1", "y1"}`, `"arc"` through `xm, ym`, `"circle"`, `"ellipse"`,
 * `"rect"`, `"polygon"`, `"polyline"`, `"spline"`), each made exact, put in chain order and
 * turned to run on, joined where ends meet within `tolerance` (0 or NaN: the pieces' effective
 * tolerance). Closed where the chain's ends meet, or with a closing side when `closed` asks.
 * Null and `last_error` (naming the piece by index) for a piece it cannot read or pieces that
 * do not chain.
 *
 * # Safety
 * `json` a NUL-terminated UTF-8 string.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_pieces(const char *json,
                                                                            bool closed,
                                                                            double tolerance);

/**
 * `profile`'s outline as piece definitions, JSON text, one per segment in order from its
 * start: a line `{x0, y0, x1, y1}`; an arc `{x0, y0, xm, ym, x1, y1}` through its middle (a
 * whole circle as two halves); anything else a cubic `"spline"` piece per Bézier (`points`
 * four, `degree` 3, `weights` four). What [`cadaclysm_blacksmith_profile_from_pieces`] reads
 * back to the same profile. Owned: release with `cadaclysm_blacksmith_string_free`. Null and
 * `last_error` for a profile with holes.
 *
 * # Safety
 * `profile` a live profile.
 */
char *cadaclysm_blacksmith_profile_pieces_json(const struct CadaclysmBlacksmithProfile *profile);

/**
 * A sketch fillet between two open profiles that meet at an end (within `tolerance`; 0 or NaN
 * their effective tolerance): JSON text `{"a": pieces, "b": pieces, "arc": piece}`, `a` and
 * `b` cut back to the tangent points, each running the way it ran, the arc from `a`'s side to
 * `b`'s. Owned: release with `cadaclysm_blacksmith_string_free`. Null and `last_error` where
 * they do not meet at an end, run straight on or fold back (lines, arcs and splines alike),
 * or the radius does not fit.
 *
 * # Safety
 * `a`, `b` live profiles.
 */
char *cadaclysm_blacksmith_profile_fillet_corner(const struct CadaclysmBlacksmithProfile *a,
                                                 const struct CadaclysmBlacksmithProfile *b,
                                                 double radius,
                                                 double tolerance);

/**
 * The exact box of `profile` in its sketch into `out` -- min x, min y, max x, max y -- over
 * the outline and the holes: the curves' own extremes, not their control points.
 *
 * # Safety
 * `profile` a live profile; `out` four writable doubles.
 */
bool cadaclysm_blacksmith_profile_bounds(const struct CadaclysmBlacksmithProfile *profile,
                                         double *out);

/**
 * `profile` walked the other way, as a new profile: its end the new start, its segments in
 * reverse order, each turned round; each hole turned round in place. Twice is the profile.
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_reversed(const struct CadaclysmBlacksmithProfile *profile);

/**
 * A polyline through `count` points (`xy`, two doubles each) in order, a straight
 * segment per side: an open chain, or `closed` with a side from the last point back
 * to the first. A side of no length is kept, so a corner dragged onto its neighbour
 * still draws. Refused for fewer than two points (three closed) or a coordinate not
 * finite.
 *
 * # Safety
 * `xy` must point at `2 * count` doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polyline(const double *xy,
                                                                         size_t count,
                                                                         bool closed);

/**
 * An arc of radius `r` about (`cx`, `cy`) from angle `a0` counter-clockwise to
 * `a1` (radians from the sketch's x axis), as one exact arc, open: the sweep is
 * taken the counter-clockwise way round, `a1` brought past `a0` when it is not.
 * Equal angles are the whole circle, closed, starting at `a0`. Refused for a radius
 * not positive and finite, or a centre or angle not finite.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_arc(double cx,
                                                                    double cy,
                                                                    double r,
                                                                    double a0,
                                                                    double a1);

/**
 * The arc from (`x0`, `y0`) through (`xm`, `ym`) to (`x1`, `y1`), as one exact
 * arc leaving the start, open: the circle through the three points, swept the way
 * round that passes the middle one. Refused when the three are in a line (two of
 * them together included) or a coordinate is not finite.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_arc_through(double x0,
                                                                            double y0,
                                                                            double xm,
                                                                            double ym,
                                                                            double x1,
                                                                            double y1);

/**
 * An ellipse about (`cx`, `cy`) with semi-axes `rx` along x and `ry` along y,
 * closed: four exact quarter conics counter-clockwise from (`cx + rx`, `cy`).
 * Refused for a semi-axis not positive and finite or a centre not finite.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_ellipse(double cx,
                                                                        double cy,
                                                                        double rx,
                                                                        double ry);

/**
 * `count` rational cubic Béziers end to end as one open profile, the first one's
 * start its start: `beziers` holds sixteen doubles each, `x y z w` per control
 * point (the point Cartesian, `z` ignored, its weight beside it) -- the record
 * [`cadaclysm_blacksmith_profile_beziers`] writes. `recognise`: a straight Bézier
 * becomes an exact line and a circular one an exact arc (consecutive pieces of one
 * circle merged into one arc), the rest kept as curves -- what a trim, an
 * extrusion or a fillet wants; otherwise every Bézier is kept as the exact rational
 * cubic it is, so a chain or a close hands the same Béziers back. Refused for no
 * Béziers, a number not finite or a weight not positive.
 *
 * # Safety
 * `beziers` must point at `16 * count` doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_beziers(const double *beziers,
                                                                             size_t count,
                                                                             bool recognise);

/**
 * How many Béziers [`cadaclysm_blacksmith_profile_beziers`] writes for `profile`.
 * 0 and `last_error` for a null profile.
 *
 * # Safety
 * `profile` live.
 */
uint32_t cadaclysm_blacksmith_profile_bezier_count(const struct CadaclysmBlacksmithProfile *profile);

/**
 * `profile` as rational cubic Béziers into `out`, sixteen doubles each -- `x y z w`
 * per control point, the point Cartesian and its weight beside it: a line one
 * straight Bézier, an arc exact conic pieces of a quarter turn or less, a Bézier
 * itself, a conic or a spline its own decomposition; the outline from its start,
 * then each hole's. `frame` null: on the sketch plane, z = 0; otherwise a frame's
 * twelve doubles -- origin, x, y, z, as every call taking a frame reads them --
 * and every point carried onto its plane (x normalised, y squared against it, z
 * not read).
 * Size `out` from [`cadaclysm_blacksmith_profile_bezier_count`]. `false` and
 * `last_error` for a null argument or a frame whose directions are parallel,
 * zero or not finite.
 *
 * # Safety
 * `profile` live; `frame` null or twelve doubles; `out` `16 * bezier_count` doubles.
 */
bool cadaclysm_blacksmith_profile_beziers(const struct CadaclysmBlacksmithProfile *profile,
                                          const double *frame,
                                          double *out);

/**
 * The closed loops among `count` profiles (`pieces`), each read by its outline's
 * two ends -- its start and where its last segment lands -- the way a CAD sketch
 * finds them: ends meet within `tolerance`; a loop is a chain of pieces through
 * corners where exactly two ends meet (a corner of three or more is ambiguous, and
 * no loop runs through it; a corner of one is an open end); a piece whose own two
 * ends meet, a closed one included, is a loop of its own. Each piece is in at most
 * one loop. Written into `out` flattened, exactly `2 * count` values: per loop its
 * length, then its pieces' indices in the order the loop runs, starting from its
 * lowest index, the loops ordered by that index; then zeros -- a length of 0 ends
 * the list, so `out[0] == 0` is no loop at all. `false` and `last_error` for a
 * refusal (a null argument, a piece with holes or nothing drawn).
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `pieces` `count` live profiles; `out` `2 * count` writable `u32`s.
 */
bool cadaclysm_blacksmith_profile_loops(const struct CadaclysmBlacksmithProfile *const *pieces,
                                        size_t count,
                                        double tolerance,
                                        uint32_t *out);

/**
 * The order [`cadaclysm_blacksmith_profile_chain`] takes `count` profiles in, into
 * `out`: for each piece from the chain's start to its end, its index, then 1 where
 * it was turned round to meet the chain, else 0 -- `2 * count` values. Refused
 * (`false`, `last_error` "chain: ...") as the chain is.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `pieces` `count` live profiles; `out` `2 * count` writable `u32`s.
 */
bool cadaclysm_blacksmith_profile_chain_order(const struct CadaclysmBlacksmithProfile *const *pieces,
                                              size_t count,
                                              double tolerance,
                                              uint32_t *out);

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
 * The region `a` or `b` covers, exactly: zero or more profiles wound boundary
 * counter-clockwise and holes clockwise, every side a piece of a side of an input, the same
 * kind of curve -- a profile list (read it with `profile_list_count` / `profile_list_get`,
 * free it with `profile_list_free`). Null (and `last_error`) for a null profile, an input
 * open or crossing itself, a negative or infinite tolerance.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `a`, `b` live profiles.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_union(const struct CadaclysmBlacksmithProfile *a,
                                                                          const struct CadaclysmBlacksmithProfile *b,
                                                                          double tolerance);

/**
 * The region of `a` that `b` does not cover, exactly, as a profile list -- see
 * [`cadaclysm_blacksmith_profile_union`] for the terms.
 *
 * # Safety
 * `a`, `b` live profiles.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_difference(const struct CadaclysmBlacksmithProfile *a,
                                                                               const struct CadaclysmBlacksmithProfile *b,
                                                                               double tolerance);

/**
 * Every region the `count` closed profiles at `profiles` split the plane into, each once, as
 * a profile list: each next profile splits every region so far into the part inside it and
 * the part outside, and what of it no region covers is a region of its own -- exact
 * booleans throughout. Which inputs hold a region: those
 * [`cadaclysm_blacksmith_profile_relationship`] calls `A_INSIDE_B` or `EQUAL`. Null (and
 * `last_error`) for a null array or profile, the boolean refusals (named by the input's
 * index). `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `profiles` `count` live profiles.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_regions(const struct CadaclysmBlacksmithProfile *const *profiles,
                                                                            size_t count,
                                                                            double tolerance);

/**
 * Where (`x`, `y`) lies against the closed profile `p`: `CADACLYSM_BLACKSMITH_CONTAINS_ON`
 * within `tolerance` of any loop (holes included; the distance exact to lines, arcs and
 * splines), else `_INSIDE` or `_OUTSIDE` by the even-odd rule. An open chain is read closed
 * by its implicit side. -1 (and `last_error`) for a null profile, a profile with no
 * segments, a point not finite, a negative or infinite tolerance. `tolerance` 0 or NaN: the
 * profile's effective tolerance.
 *
 * # Safety
 * `p` a live profile.
 */
int32_t cadaclysm_blacksmith_profile_contains(const struct CadaclysmBlacksmithProfile *p,
                                              double x,
                                              double y,
                                              double tolerance);

/**
 * How the regions of the closed profiles `a` and `b` stand to each other: a
 * `CADACLYSM_BLACKSMITH_RELATION_*` code, from the area of their exact common region against
 * each one's area (slack: `tolerance` times the shorter perimeter) and whether their
 * boundaries meet. -1 (and `last_error`) for a null profile, an input open or crossing
 * itself, a negative or infinite tolerance. `tolerance` 0 or NaN: the inputs' effective
 * tolerance.
 *
 * # Safety
 * `a`, `b` live profiles.
 */
int32_t cadaclysm_blacksmith_profile_relationship(const struct CadaclysmBlacksmithProfile *a,
                                                  const struct CadaclysmBlacksmithProfile *b,
                                                  double tolerance);

/**
 * The largest and smallest distance between the outlines (every loop) of `a` and `b`, both
 * ways round, written to `out10`: the largest distance, its point on `a` (x, y), its point
 * on `b` (x, y), then the smallest distance and its two points the same way. Every figure
 * within `tolerance` of the true one. False (and `last_error`) for a null profile or
 * `out10`, a profile with no segments, a negative or infinite tolerance, a spline that does
 * not evaluate. `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `a`, `b` live profiles; `out10` room for 10 doubles.
 */
bool cadaclysm_blacksmith_profile_deviation(const struct CadaclysmBlacksmithProfile *a,
                                            const struct CadaclysmBlacksmithProfile *b,
                                            double tolerance,
                                            double *out10);

/**
 * `p` grown by `distance` (shrunk where negative) as [`cadaclysm_blacksmith_profile_offset`]
 * does, with every corner where the moved sides part styled `corner`
 * (`CADACLYSM_BLACKSMITH_OFFSET_ROUND`, `_SHARP`, `_SMOOTH`, `_CHAMFER`): round is
 * `profile_offset` itself; for the others each round join that came through whole is
 * replaced, by an exact boolean, with the styled curve. A profile list. Null (and
 * `last_error`) for the `profile_offset` refusals and an unknown style.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_offset_corner(const struct CadaclysmBlacksmithProfile *p,
                                                                                  double distance,
                                                                                  double tolerance,
                                                                                  uint32_t corner);

/**
 * `p` read as an open chain (its implicit closing side and holes ignored) and offset by
 * `distance`, as a profile list. `end` `CADACLYSM_BLACKSMITH_OFFSET_END_NONE`: the one-sided
 * offset, `distance` to the right of travel (negative, the left), open chains with the
 * overlaps at inside corners trimmed. `_FLAT` / `_ROUND`: the closed outline both sides at
 * `|distance|`, each end capped by a line across or a half circle. `corner` styles the
 * joins as in [`cadaclysm_blacksmith_profile_offset_corner`]. Null (and `last_error`) for a
 * null profile, a distance not finite (or 0 with ends), a negative or infinite tolerance,
 * an unknown style, a chain with no sides.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_offset_open(const struct CadaclysmBlacksmithProfile *p,
                                                                                double distance,
                                                                                double tolerance,
                                                                                uint32_t corner,
                                                                                uint32_t end);

/**
 * `p` with every run of consecutive straight segments simplified by Douglas–Peucker within
 * `tolerance` (a vertex goes where the run stays within `tolerance` of it), as a new
 * profile. Arcs and splines, and the ends of every run, are kept. `open` reads `p` as an
 * open chain; closed, it is closed by its implicit side first. Null (and `last_error`) for
 * a null profile, a negative or infinite tolerance. `tolerance` 0 or NaN: the profile's
 * effective tolerance.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_reduce_segments(const struct CadaclysmBlacksmithProfile *p,
                                                                                double tolerance,
                                                                                bool open);

/**
 * `p` with neighbouring segments that are one curve made one, as a new profile: two lines
 * turning less than `angle_tolerance` radians, two arcs on one circle turning one way
 * (unless together they would close it). `include_seam` merges a closed loop's last and
 * first segments too. Null (and `last_error`) for a null profile or an angle outside
 * `[0, pi)`.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_merge_colinear(const struct CadaclysmBlacksmithProfile *p,
                                                                               double angle_tolerance,
                                                                               bool open,
                                                                               bool include_seam);

/**
 * `p`'s outer loop cut into open pieces wherever the direction of travel turns by more than
 * `angle` radians at a joint, as a profile list. A closed loop (`open` false) with no kink
 * comes back whole; with kinks, as open pieces starting at its first. Null (and
 * `last_error`) for a null profile, an angle outside `[0, pi]`, no segments.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_break_at_kinks(const struct CadaclysmBlacksmithProfile *p,
                                                                                   double angle,
                                                                                   bool open);

/**
 * 1 where the closed profile `p` is convex -- no holes, and its outer loop turns one way
 * only (every joint, arc and spline) through one full turn -- 0 where not; `strict` also
 * refuses a joint between two lines that does not turn. -1 (and `last_error`) for a null
 * profile, no segments, a spline that does not evaluate.
 *
 * # Safety
 * `p` a live profile.
 */
int32_t cadaclysm_blacksmith_profile_is_convex(const struct CadaclysmBlacksmithProfile *p,
                                               bool strict);

/**
 * The open chain `p` closed by moving its end onto its start where the two are within
 * `tolerance`, as a new profile: a line's end moves, an arc's centre moves onto the
 * bisector of its new chord, a Bézier's end moves with its last inner control point, a
 * spline's last control point moves. Null (and `last_error`) for a null profile, a gap
 * wider than `tolerance`, a chain that closed would enclose nothing. `tolerance` 0 or NaN:
 * the profile's effective tolerance.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_make_closed(const struct CadaclysmBlacksmithProfile *p,
                                                                            double tolerance);

/**
 * The closed profile `p` with its outer loop restarted at its point nearest (`x`, `y`), as a
 * new profile: the segment there split exactly and the loop rotated; a point at a joint
 * rotates it without a split. Holes kept. Null (and `last_error`) for a null profile, no
 * segments, a point not finite.
 *
 * # Safety
 * `p` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_with_seam(const struct CadaclysmBlacksmithProfile *p,
                                                                          double x,
                                                                          double y);

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
 * A set from flat rings: `ring_count` rings of `ring_sizes[r]` points each, read from `xy`, in
 * `polygon_count` polygons of `polygon_rings[p]` rings each (outer first, then holes). Rings are
 * kept as written -- either winding, a repeated closing point dropped -- and not re-cut: rings
 * that cross themselves or each other want
 * [`cadaclysm_blacksmith_polygon_set_clean`]. Overlapping polygons are allowed; every operation
 * treats the set as their union. `polygon_count = 0` is the empty set.
 *
 * Null and `last_error` for a null array with a count above 0, a NaN or infinite coordinate,
 * counts that do not add up, a polygon of no rings or a ring of fewer than 3 points.
 *
 * # Safety
 * `xy` readable for twice the sum of `ring_sizes`, `ring_sizes` for `ring_count` and
 * `polygon_rings` for `polygon_count`, or null with their count 0.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_from_rings(const double *xy,
                                                                                  const uint32_t *ring_sizes,
                                                                                  uint32_t ring_count,
                                                                                  const uint32_t *polygon_rings,
                                                                                  uint32_t polygon_count);

/**
 * Free a set. Null is a no-op.
 *
 * # Safety
 * `set` null or a live handle, not used again.
 */
void cadaclysm_blacksmith_polygon_set_free(struct CadaclysmBlacksmithPolygonSet *set);

/**
 * The set's rings, flat, into `out` (borrowed from the set: see
 * [`CadaclysmBlacksmithPolygonSetView`]). `false` and `last_error` for a null set or `out`.
 *
 * # Safety
 * `set` live; `out` writable for one view.
 */
bool cadaclysm_blacksmith_polygon_set_view(const struct CadaclysmBlacksmithPolygonSet *set,
                                           struct CadaclysmBlacksmithPolygonSetView *out);

/**
 * The set re-cut into valid polygons: crossings resolved, overlaps merged (what its rings wind
 * round at least once). Null and `last_error` for a null set.
 *
 * # Safety
 * `set` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_clean(const struct CadaclysmBlacksmithPolygonSet *set);

/**
 * Everything in `a` or `b`. Null and `last_error` for a null set.
 *
 * # Safety
 * `a` and `b` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_union(const struct CadaclysmBlacksmithPolygonSet *a,
                                                                             const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * What `a` and `b` share. Null and `last_error` for a null set.
 *
 * # Safety
 * `a` and `b` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_intersection(const struct CadaclysmBlacksmithPolygonSet *a,
                                                                                    const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * `a` with `b` taken away. Null and `last_error` for a null set.
 *
 * # Safety
 * `a` and `b` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_difference(const struct CadaclysmBlacksmithPolygonSet *a,
                                                                                  const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * What is in exactly one of `a` and `b`. Null and `last_error` for a null set.
 *
 * # Safety
 * `a` and `b` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_symmetric_difference(const struct CadaclysmBlacksmithPolygonSet *a,
                                                                                            const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * Everything in any of the `count` sets, merged in one pass (`count = 0`: the empty set). Null and
 * `last_error` for a null array with `count` above 0 or a null set in it, by index.
 *
 * # Safety
 * `sets` readable for `count` pointers, each live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_union_all(const struct CadaclysmBlacksmithPolygonSet *const *sets,
                                                                                 uint32_t count);

/**
 * The area `a` and `b` share, without building their intersection. NaN and `last_error` for a
 * null set.
 *
 * # Safety
 * `a` and `b` live.
 */
double cadaclysm_blacksmith_polygon_set_intersection_area(const struct CadaclysmBlacksmithPolygonSet *a,
                                                          const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * The area of `a` outside `b`, without building the difference. NaN and `last_error` for a
 * null set.
 *
 * # Safety
 * `a` and `b` live.
 */
double cadaclysm_blacksmith_polygon_set_difference_area(const struct CadaclysmBlacksmithPolygonSet *a,
                                                        const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * The set grown by `distance` (shrunk where it is negative; cleaned at 0). Corners that open up
 * are joined by `join`: 0 an arc of `quad_segs` segments a quarter turn, 1 a mitre reaching at
 * most `mitre_limit` times the distance (squared off past it), 2 a bevel. The curve is built as
 * GEOS builds it, so the result is shapely's to within rounding. Null and `last_error` for a null
 * set, a distance that is not finite, `quad_segs` outside 1..=1024, an unknown join or a mitre
 * limit that is not a positive number.
 *
 * # Safety
 * `set` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_buffer(const struct CadaclysmBlacksmithPolygonSet *set,
                                                                              double distance,
                                                                              uint32_t quad_segs,
                                                                              uint32_t join,
                                                                              double mitre_limit);

/**
 * The region within `distance` (> 0) of the polyline of `point_count` points `xy`. `join` as
 * [`cadaclysm_blacksmith_polygon_set_buffer`]; the ends `cap`ped 0 round, 1 flat (square across
 * the end), 2 square (carried on by the distance). A single point with a round cap is a disc.
 * Null and `last_error` for no points, a non-finite coordinate, a distance that is not positive,
 * or a bad join, cap or `quad_segs`.
 *
 * # Safety
 * `xy` readable for `2 point_count` doubles.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_buffer_polyline(const double *xy,
                                                                                       uint32_t point_count,
                                                                                       double distance,
                                                                                       uint32_t quad_segs,
                                                                                       uint32_t join,
                                                                                       double mitre_limit,
                                                                                       uint32_t cap);

/**
 * The set with every corner mapped by `x' = m[0] x + m[1] y + m[4]`, `y' = m[2] x + m[3] y +
 * m[5]` (a mirroring map re-winds the rings). Null and `last_error` for a null set or matrix, or a
 * non-finite entry.
 *
 * # Safety
 * `set` live; `m` readable for 6 doubles.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_polygon_set_transform(const struct CadaclysmBlacksmithPolygonSet *set,
                                                                                 const double *m);

/**
 * The area, holes taken off. NaN and `last_error` for a null set.
 *
 * # Safety
 * `set` live.
 */
double cadaclysm_blacksmith_polygon_set_area(const struct CadaclysmBlacksmithPolygonSet *set);

/**
 * The length of every ring, holes included. NaN and `last_error` for a null set.
 *
 * # Safety
 * `set` live.
 */
double cadaclysm_blacksmith_polygon_set_perimeter(const struct CadaclysmBlacksmithPolygonSet *set);

/**
 * `[min x, min y, max x, max y]` into `out`. `false` and `last_error` for a null set or `out`, or
 * an empty set.
 *
 * # Safety
 * `set` live; `out` writable for 4 doubles.
 */
bool cadaclysm_blacksmith_polygon_set_bounds(const struct CadaclysmBlacksmithPolygonSet *set,
                                             double *out);

/**
 * The centre of area `(x, y)` into `out`, summed as GEOS sums it. `false` and `last_error` for a
 * null set or `out`, or a set with no area.
 *
 * # Safety
 * `set` live; `out` writable for 2 doubles.
 */
bool cadaclysm_blacksmith_polygon_set_centroid(const struct CadaclysmBlacksmithPolygonSet *set,
                                               double *out);

/**
 * Where each of `point_count` points `xy` is, into `out`: 1 inside, 0 on the outline, -1
 * outside. `false` and `last_error` for a null set, array or `out`, or a non-finite coordinate.
 *
 * # Safety
 * `set` live; `xy` readable for `2 point_count` doubles; `out` writable for `point_count`.
 */
bool cadaclysm_blacksmith_polygon_set_locate(const struct CadaclysmBlacksmithPolygonSet *set,
                                             const double *xy,
                                             uint32_t point_count,
                                             int32_t *out);

/**
 * 1 when `b` lies in `a` -- none of it outside, some of it inside; flush against the outline
 * counts -- else 0 (an empty `b` is in nothing). -1 and `last_error` for a null set.
 *
 * # Safety
 * `a` and `b` live.
 */
int32_t cadaclysm_blacksmith_polygon_set_contains(const struct CadaclysmBlacksmithPolygonSet *a,
                                                  const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * 1 when `a` and `b` share any point, outlines included, else 0. -1 and `last_error` for a null
 * set.
 *
 * # Safety
 * `a` and `b` live.
 */
int32_t cadaclysm_blacksmith_polygon_set_intersects(const struct CadaclysmBlacksmithPolygonSet *a,
                                                    const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * 1 when the polyline of `point_count` points `xy` lies in the set -- none of it outside, some
 * of it strictly inside (one lying wholly along the outline is not) -- else 0. -1 and
 * `last_error` for a null set or array, no points, or a non-finite coordinate.
 *
 * # Safety
 * `set` live; `xy` readable for `2 point_count` doubles.
 */
int32_t cadaclysm_blacksmith_polygon_set_contains_polyline(const struct CadaclysmBlacksmithPolygonSet *set,
                                                           const double *xy,
                                                           uint32_t point_count);

/**
 * 1 when the polyline of `point_count` points `xy` meets the set anywhere, outline included,
 * else 0. -1 and `last_error` as [`cadaclysm_blacksmith_polygon_set_contains_polyline`].
 *
 * # Safety
 * `set` live; `xy` readable for `2 point_count` doubles.
 */
int32_t cadaclysm_blacksmith_polygon_set_intersects_polyline(const struct CadaclysmBlacksmithPolygonSet *set,
                                                             const double *xy,
                                                             uint32_t point_count);

/**
 * The least distance between `a` and `b` (0 where they meet). NaN and `last_error` for a null
 * set.
 *
 * # Safety
 * `a` and `b` live.
 */
double cadaclysm_blacksmith_polygon_set_distance(const struct CadaclysmBlacksmithPolygonSet *a,
                                                 const struct CadaclysmBlacksmithPolygonSet *b);

/**
 * The least distance from the set to the polyline of `point_count` points `xy` -- one point is a
 * polyline too -- 0 where they meet. NaN and `last_error` for a null set or array, no points, or
 * a non-finite coordinate.
 *
 * # Safety
 * `set` live; `xy` readable for `2 point_count` doubles.
 */
double cadaclysm_blacksmith_polygon_set_distance_to_polyline(const struct CadaclysmBlacksmithPolygonSet *set,
                                                             const double *xy,
                                                             uint32_t point_count);

/**
 * The least distance from the set's outline to the point `(x, y)`, inside or out. NaN and
 * `last_error` for a null or empty set or a non-finite coordinate.
 *
 * # Safety
 * `set` live.
 */
double cadaclysm_blacksmith_polygon_set_boundary_distance(const struct CadaclysmBlacksmithPolygonSet *set,
                                                          double x,
                                                          double y);

/**
 * The parts of the polyline of `point_count` points `xy` that lie in the set, outline included,
 * as polylines in the line's own order. Null and `last_error` for a null set or array, no
 * points, or a non-finite coordinate.
 *
 * # Safety
 * `set` live; `xy` readable for `2 point_count` doubles. Free the answer with
 * [`cadaclysm_blacksmith_polygon_set_lines_free`].
 */
struct CadaclysmBlacksmithPolygonSetLines *cadaclysm_blacksmith_polygon_set_clip_polyline(const struct CadaclysmBlacksmithPolygonSet *set,
                                                                                          const double *xy,
                                                                                          uint32_t point_count);

/**
 * The polylines, flat, into `out` (borrowed from the handle). `false` and `last_error` for a null
 * handle or `out`.
 *
 * # Safety
 * `lines` live; `out` writable for one view.
 */
bool cadaclysm_blacksmith_polygon_set_lines_view(const struct CadaclysmBlacksmithPolygonSetLines *lines,
                                                 struct CadaclysmBlacksmithPolygonSetLinesView *out);

/**
 * `profile` flattened to a polygon set: every arc and free-form side walked in steps that keep
 * it within `tolerance` (NaN or 0: the profile's effective tolerance) -- the same outline
 * `cadaclysm_blacksmith_profile_polylines` draws -- its outer loop and holes kept as they run.
 * Null and `last_error` for a null profile, a loop that does not close, or a tolerance that is
 * not positive.
 *
 * # Safety
 * `profile` live.
 */
struct CadaclysmBlacksmithPolygonSet *cadaclysm_blacksmith_profile_polygon_set(const struct CadaclysmBlacksmithProfile *profile,
                                                                               double tolerance);

/**
 * Each polygon of `set` as a straight-sided profile with its holes (uncoloured; the outer loop
 * counter-clockwise, holes clockwise), as a profile list -- empty for the empty set. Null and
 * `last_error` for a null set.
 *
 * # Safety
 * `set` live. Free the list with `cadaclysm_blacksmith_profile_list_free`.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_polygon_set_profiles(const struct CadaclysmBlacksmithPolygonSet *set);

/**
 * Free polylines. Null is a no-op.
 *
 * # Safety
 * `lines` null or a live handle, not used again.
 */
void cadaclysm_blacksmith_polygon_set_lines_free(struct CadaclysmBlacksmithPolygonSetLines *lines);

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
 * The default rule for sheet `thickness` thick into `out`: bend radius the thickness,
 * K-factor 0.44, rectangular bend reliefs, round corner reliefs, every size from the
 * thickness. `false` and `last_error` (starting `sheet_rule_default: `), `out` untouched,
 * for a null `out` and a thickness not positive and finite.
 *
 * # Safety
 * `out` one `CadaclysmBlacksmithSheetRule`.
 */
bool cadaclysm_blacksmith_sheet_rule_default(double thickness,
                                             struct CadaclysmBlacksmithSheetRule *out);

/**
 * The base flange: `profile` as a flat sheet under `frame` (twelve doubles), its top in the
 * frame's plane, the sheet below it. Null and `last_error` (starting `sheet_base: `) for a
 * null input, a bad rule (a code out of range, a length negative) and a profile that does
 * not extrude.
 *
 * # Safety
 * `profile` live; `frame` twelve doubles; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_base(const struct CadaclysmBlacksmithProfile *profile,
                                                                 const double *frame,
                                                                 const struct CadaclysmBlacksmithSheetRule *rule,
                                                                 double tolerance);

/**
 * A contour flange: the open path of `point_count` points at `path` (x, y pairs in
 * `frame`'s plane: the sheet seen from its side), `width` deep along the frame's z, each
 * corner a bend of the rule's radius. Null and `last_error` (starting `sheet_contour: `) for
 * fewer than two points, a segment too short for its bends and a bad rule.
 *
 * # Safety
 * `path` `2 * point_count` doubles; `frame` twelve doubles; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_contour(const double *path,
                                                                    size_t point_count,
                                                                    const double *frame,
                                                                    double width,
                                                                    const struct CadaclysmBlacksmithSheetRule *rule,
                                                                    double tolerance);

/**
 * A lofted flange between two open polylines: `a_count` points at `a` and `b_count` at `b`
 * (x, y, z triples, at least two each), the sheet's top face. The strip between them is cut
 * into facets (neighbours in one plane merged) and every crease is a bend of the rule's
 * radius, so the part unfolds like any other; an arc is sampled by the caller, one facet per
 * chord. The sheet lies under the facets' normal, `along a x towards b` (reverse both
 * profiles to put it on the other side). Null and `last_error` (starting
 * `sheet_lofted_flange: `) for fewer than two points, a repeated point, a facet with no area,
 * a facet its bends' set-backs leave nothing of, and a bad rule.
 *
 * # Safety
 * `a` `3 * a_count` doubles; `b` `3 * b_count` doubles; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_lofted_flange(const double *a,
                                                                          size_t a_count,
                                                                          const double *b,
                                                                          size_t b_count,
                                                                          const struct CadaclysmBlacksmithSheetRule *rule,
                                                                          double tolerance);

/**
 * Edge flanges on the `count` edges at `edges` (indices into the list
 * `cadaclysm_blacksmith_edge` walks: edges of a broad face of a sheet body), each turned
 * `angle` (> 0 up, towards the side the edge's face looks) and `length` high outside.
 * `offsets` null for flanges the full length of their edges, else two doubles: how far in
 * each flange starts from its edge's two ends (bend reliefs are cut). Two flanges meeting at
 * a corner are mitred with the rule's gap. Null and `last_error` (starting `sheet_flange: `)
 * for no edges, an edge that is not on a broad face's rim, a solid that is not sheet metal,
 * an angle not in (0, 1.75 pi] either way, and a length shorter than the bend.
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `offsets` null or two doubles; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_flange(const struct CadaclysmBlacksmithSolid *solid,
                                                                   const uint32_t *edges,
                                                                   size_t count,
                                                                   double angle,
                                                                   double length,
                                                                   const double *offsets,
                                                                   const struct CadaclysmBlacksmithSheetRule *rule,
                                                                   double tolerance);

/**
 * Hems on the `count` edges at `edges`: `kind` one of `CADACLYSM_BLACKSMITH_HEM_*`, `length`
 * the lip (flat, open, teardrop, double), `gap` the gap inside (0: the thickness; a rope
 * hem's rod), `angle` a rolled hem's turn (0: 1.5 pi). Null and `last_error` (starting
 * `sheet_hem: `) for a kind out of range and what
 * [`cadaclysm_blacksmith_sheet_flange`] refuses.
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_hem(const struct CadaclysmBlacksmithSolid *solid,
                                                                const uint32_t *edges,
                                                                size_t count,
                                                                uint32_t kind,
                                                                double length,
                                                                double gap,
                                                                double angle,
                                                                const struct CadaclysmBlacksmithSheetRule *rule,
                                                                double tolerance);

/**
 * A bend on the line through two points (`line`, six doubles) across flat broad face `face`
 * of a sheet body: the material on the line's left (seen from the face's outside) turned
 * `angle`. Null and `last_error` (starting `sheet_fold: `) for a face that is not a flat
 * broad face, a line that does not cross it, a fold through another bend and a fold that
 * collides with the part.
 *
 * # Safety
 * `solid` live; `line` six doubles; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_fold(const struct CadaclysmBlacksmithSolid *solid,
                                                                 uint32_t face,
                                                                 const double *line,
                                                                 double angle,
                                                                 const struct CadaclysmBlacksmithSheetRule *rule,
                                                                 double tolerance);

/**
 * Rips along the `count` edges at `edges` (sharp edges between two walls of a shelled
 * solid): a slot `gap` wide (0: a tenth of the shell's thickness) through the wall, so
 * [`cadaclysm_blacksmith_sheet_convert`] can lay it flat. Null and `last_error` (starting
 * `sheet_rip: `) for an edge that is not sharp between two flat faces of constant thickness.
 *
 * # Safety
 * `solid` live; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_rip(const struct CadaclysmBlacksmithSolid *solid,
                                                                const uint32_t *edges,
                                                                size_t count,
                                                                double gap,
                                                                double tolerance);

/**
 * A shelled solid of constant thickness made sheet metal from face `fixed_face`: every
 * sharp edge between two flat broad faces a bend of the rule's radius, the outside kept.
 * Null and `last_error` (starting `sheet_convert: `) for a solid not of one thickness, a
 * closed loop of walls that needs a rip, and a rule thickness not the solid's.
 *
 * # Safety
 * `solid` live; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_convert(const struct CadaclysmBlacksmithSolid *solid,
                                                                    uint32_t fixed_face,
                                                                    const struct CadaclysmBlacksmithSheetRule *rule,
                                                                    double tolerance);

/**
 * The rule's corner relief cut at every corner where two bend zones end close together.
 * Null and `last_error` (starting `sheet_corner_relief: `) for a solid that is not sheet
 * metal.
 *
 * # Safety
 * `solid` live; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_corner_relief(const struct CadaclysmBlacksmithSolid *solid,
                                                                          const struct CadaclysmBlacksmithSheetRule *rule,
                                                                          double tolerance);

/**
 * A rip between two points (`points`, six doubles) on flat broad face `face`: a slot `gap`
 * wide (0: a tenth of the thickness) through that wall only. An end on the face's outline
 * breaks through it; an end inside the face stops there. Null and `last_error` (starting
 * `sheet_rip_points: `) for a face that is not a flat broad face and a point off it.
 *
 * # Safety
 * `solid` live; `points` six doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_rip_points(const struct CadaclysmBlacksmithSolid *solid,
                                                                       uint32_t face,
                                                                       const double *points,
                                                                       double gap,
                                                                       double tolerance);

/**
 * The wall under broad face `face` (flat or a bend) removed through the thickness. Null and
 * `last_error` (starting `sheet_rip_face: `) for a face that is not a broad face and a rip
 * that leaves nothing.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_rip_face(const struct CadaclysmBlacksmithSolid *solid,
                                                                     uint32_t face,
                                                                     double tolerance);

/**
 * Two walls joined by a bend of the rule's radius: `edge_a` and `edge_b` are outline edges
 * where each wall's broad face meets its square end, parallel and of one extent. Each wall
 * runs on to the other's far face and the corner gets the bend, the outer mould line kept;
 * walls in one plane are joined flat. Null and `last_error` (starting `sheet_join: `) for
 * edges that are not wall ends, not parallel or of different extent, and walls that overlap
 * or lie parallel in two planes.
 *
 * # Safety
 * `solid` live; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_join(const struct CadaclysmBlacksmithSolid *solid,
                                                                 uint32_t edge_a,
                                                                 uint32_t edge_b,
                                                                 const struct CadaclysmBlacksmithSheetRule *rule,
                                                                 double tolerance);

/**
 * Rounds of `radius` on the `count` thickness edges at `edges` (across the sheet at a corner
 * of its outline, on a flat region): each corner of the flat pattern rounded (cut on a convex
 * corner, filled on a concave one) and the part folded again. Null and `last_error`
 * (starting `sheet_fillet: `) for an edge that is not a thickness edge and a round that runs
 * past the sides beside it.
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_fillet(const struct CadaclysmBlacksmithSolid *solid,
                                                                   const uint32_t *edges,
                                                                   size_t count,
                                                                   double radius,
                                                                   const struct CadaclysmBlacksmithSheetRule *rule,
                                                                   double tolerance);

/**
 * Chamfers `distance` along both sides on the `count` thickness edges at `edges`: see
 * [`cadaclysm_blacksmith_sheet_fillet`]. Null and `last_error` (starting `sheet_chamfer: `).
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sheet_chamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                                    const uint32_t *edges,
                                                                    size_t count,
                                                                    double distance,
                                                                    const struct CadaclysmBlacksmithSheetRule *rule,
                                                                    double tolerance);

/**
 * Whether `solid` is sheet metal: two broad sides of constant thickness, flat faces and
 * cylindrical bends, side faces one thickness wide. `false` for null.
 *
 * # Safety
 * `solid` null or live.
 */
bool cadaclysm_blacksmith_is_sheet_metal(const struct CadaclysmBlacksmithSolid *solid,
                                         double tolerance);

/**
 * The faces of every bend of a sheet body (two a bend, inner and outer) into `out`. Returns
 * how many, or -1 (and `last_error`, starting `sheet_bend_faces: `, `out` untouched) for a
 * null input or a solid that is not sheet metal.
 *
 * # Safety
 * `solid` live; `out` room for `face_count` `uint32_t`s.
 */
int32_t cadaclysm_blacksmith_sheet_bend_faces(const struct CadaclysmBlacksmithSolid *solid,
                                              double tolerance,
                                              uint32_t *out);

/**
 * `solid` read as sheet metal from `fixed_face` (`CADACLYSM_BLACKSMITH_NONE`: its largest
 * flat broad face) into `out`. `false` and `last_error` (starting `sheet_info: `), `out`
 * untouched, for a null input and a solid that is not sheet metal.
 *
 * # Safety
 * `solid` live; `out` one `CadaclysmBlacksmithSheetInfo`.
 */
bool cadaclysm_blacksmith_sheet_info(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t fixed_face,
                                     double tolerance,
                                     struct CadaclysmBlacksmithSheetInfo *out);

/**
 * Every bend of `solid` read from `fixed_face` (as [`cadaclysm_blacksmith_sheet_info`]) into
 * `out`. Returns how many, or -1 (and `last_error`, starting `sheet_bends: `, `out`
 * untouched) for what `sheet_info` refuses.
 *
 * # Safety
 * `solid` live; `out` room for `bend_count` `CadaclysmBlacksmithBendInfo`s.
 */
int32_t cadaclysm_blacksmith_sheet_bends(const struct CadaclysmBlacksmithSolid *solid,
                                         uint32_t fixed_face,
                                         double tolerance,
                                         struct CadaclysmBlacksmithBendInfo *out);

/**
 * `solid` unfolded from flat broad face `fixed_face` under `rule`: every bend laid flat at
 * its allowance. Null and `last_error` (starting `flat_pattern: `) for a solid that is not
 * sheet metal, a face that is not a flat broad face, a rule whose thickness is not the
 * solid's, and a flat that overlaps itself.
 *
 * # Safety
 * `solid` live; `rule` one rule. Free the result with `cadaclysm_blacksmith_flat_pattern_free`.
 */
struct CadaclysmBlacksmithFlatPattern *cadaclysm_blacksmith_flat_pattern(const struct CadaclysmBlacksmithSolid *solid,
                                                                         uint32_t fixed_face,
                                                                         const struct CadaclysmBlacksmithSheetRule *rule,
                                                                         double tolerance);

/**
 * The flat body: the outline extruded the thickness down from the frame. A new solid; null
 * (and `last_error`) for null.
 *
 * # Safety
 * `fp` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_flat_pattern_body(const struct CadaclysmBlacksmithFlatPattern *fp);

/**
 * The flat's outline, in the frame's plane. A new profile; null (and `last_error`) for null.
 *
 * # Safety
 * `fp` live.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_flat_pattern_profile(const struct CadaclysmBlacksmithFlatPattern *fp);

/**
 * The flat's frame (twelve doubles: origin, x, y, z) into `out`; the sheet lies below its
 * plane. `false` (and `last_error`) for a null input.
 *
 * # Safety
 * `fp` live; `out` twelve doubles.
 */
bool cadaclysm_blacksmith_flat_pattern_frame(const struct CadaclysmBlacksmithFlatPattern *fp,
                                             double *out);

/**
 * How many bend zones the flat pattern draws. 0 (and `last_error`) for null.
 *
 * # Safety
 * `fp` live.
 */
uint32_t cadaclysm_blacksmith_flat_pattern_bend_count(const struct CadaclysmBlacksmithFlatPattern *fp);

/**
 * Bend zone `i` into `out`. `false` (and `last_error`, `out` untouched) for a null input or
 * `i` out of range.
 *
 * # Safety
 * `fp` live; `out` one `CadaclysmBlacksmithFlatBend`.
 */
bool cadaclysm_blacksmith_flat_pattern_bend(const struct CadaclysmBlacksmithFlatPattern *fp,
                                            uint32_t i,
                                            struct CadaclysmBlacksmithFlatBend *out);

/**
 * How many bends the part has, as [`cadaclysm_blacksmith_fold_flat`] takes them (a bend cut
 * in two by a hole is one bend and two zones). 0 (and `last_error`) for null.
 *
 * # Safety
 * `fp` live.
 */
uint32_t cadaclysm_blacksmith_flat_pattern_fold_bend_count(const struct CadaclysmBlacksmithFlatPattern *fp);

/**
 * The part's bend `i` into `out`. `false` (and `last_error`, `out` untouched) for a null
 * input or `i` out of range.
 *
 * # Safety
 * `fp` live; `out` one `CadaclysmBlacksmithBend`.
 */
bool cadaclysm_blacksmith_flat_pattern_fold_bend(const struct CadaclysmBlacksmithFlatPattern *fp,
                                                 uint32_t i,
                                                 struct CadaclysmBlacksmithBend *out);

/**
 * The flat pattern alone on a page in `units` (as `cadaclysm_blacksmith_page_new`), as DXF
 * R2000 text: what [`cadaclysm_blacksmith_page_add_flat_pattern`] draws at the origin. Free
 * with `cadaclysm_blacksmith_string_free`. Null (and `last_error`, starting
 * `flat_pattern_dxf: `) for a null input, units unknown and flags out of range.
 *
 * # Safety
 * `fp` live.
 */
char *cadaclysm_blacksmith_flat_pattern_dxf(const struct CadaclysmBlacksmithFlatPattern *fp,
                                            uint32_t units,
                                            uint32_t flags);

/**
 * Release a flat pattern. Null is a no-op.
 *
 * # Safety
 * `fp` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_flat_pattern_free(struct CadaclysmBlacksmithFlatPattern *fp);

/**
 * A flat outline folded: `profile` under `frame` (twelve doubles), each of the `count`
 * bends at `bends` a bend, under `rule` -- a flat pattern edited and folded again. Null and
 * `last_error` (starting `fold_flat: `) for a bend line that does not cross the outline,
 * two bends that cross or overlap, and a fold that collides with itself.
 *
 * # Safety
 * `profile` live; `frame` twelve doubles; `bends` `count` bends; `rule` one rule.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fold_flat(const struct CadaclysmBlacksmithProfile *profile,
                                                                const double *frame,
                                                                const struct CadaclysmBlacksmithBend *bends,
                                                                size_t count,
                                                                const struct CadaclysmBlacksmithSheetRule *rule,
                                                                double tolerance);

/**
 * The flat pattern drawn on `page` at (`x`, `y`), 1:1: its outline on layer `OUTLINE`, each
 * bend line on `BEND_UP` (green) or `BEND_DOWN` (red) in the centre linetype; `flags`
 * (`CADACLYSM_BLACKSMITH_FLAT_*`) add the zones' edges on `BEND_EXTENT`, a ruled table of
 * the bends under the outline on `BEND_TABLE`, a label on each bend line, a bend note under
 * each on `BEND_NOTE`, the overall width and height dimensioned on `DIMENSION`, and the
 * folded part's front view (looking along the flat frame's y, its z up) right of the flat on
 * `FOLDED` and `FOLDED_HIDDEN`. Returns how many entities were added, or -1 (and
 * `last_error`, starting `page_add_flat_pattern: `) for a null input, a position not finite
 * and flags out of range.
 *
 * # Safety
 * `page` and `fp` live.
 */
int32_t cadaclysm_blacksmith_page_add_flat_pattern(struct CadaclysmBlacksmithPage *page,
                                                   const struct CadaclysmBlacksmithFlatPattern *fp,
                                                   double x,
                                                   double y,
                                                   uint32_t flags);

/**
 * The `face_count` faces at `faces` of `solid` (none: all) laid flat in the xy plane --
 * Rhino's `Unroller`. Planes, cylinders and cones unroll exactly; any other surface whose
 * curvature vanishes within `tolerance` by its own flattening. Faces sharing an edge stay
 * joined unless joined they would overlap (or `explode`), the largest face placed first;
 * the edges between faces laid apart are reported cut. The `curve_count` curves at `curves`
 * follow onto the flat (pieces where they cross a cut), the `point_count` points at `points`
 * (x, y, z triples) to their spots. A face that is not developable is left out and reported.
 * Null and `last_error` (starting `unroll: `) for a face out of range and no developable face.
 *
 * # Safety
 * `solid` live; `faces` `face_count` indices; `curves` `curve_count` live curves; `points`
 * `3 * point_count` doubles. Free the result with `cadaclysm_blacksmith_unrolled_free`.
 */
struct CadaclysmBlacksmithUnrolled *cadaclysm_blacksmith_unroll(const struct CadaclysmBlacksmithSolid *solid,
                                                                const uint32_t *faces,
                                                                size_t face_count,
                                                                const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                size_t curve_count,
                                                                const double *points,
                                                                size_t point_count,
                                                                bool explode,
                                                                double tolerance);

/**
 * The flat sheet: an open shell in the xy plane. A new solid; null (and `last_error`) for
 * null.
 *
 * # Safety
 * `u` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unrolled_sheet(const struct CadaclysmBlacksmithUnrolled *u);

/**
 * How many faces the sheet has. 0 (and `last_error`) for null.
 *
 * # Safety
 * `u` live.
 */
uint32_t cadaclysm_blacksmith_unrolled_face_count(const struct CadaclysmBlacksmithUnrolled *u);

/**
 * The source face of each sheet face, in the sheet's face order, into `out`. `false` (and
 * `last_error`) for a null input.
 *
 * # Safety
 * `u` live; `out` room for `unrolled_face_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_unrolled_faces(const struct CadaclysmBlacksmithUnrolled *u,
                                         uint32_t *out);

/**
 * How many pieces curve `curve` (in the order given to `unroll`) came out in: 0 where it
 * missed every face. 0 (and `last_error`) for a null input or a curve out of range.
 *
 * # Safety
 * `u` live.
 */
uint32_t cadaclysm_blacksmith_unrolled_curve_piece_count(const struct CadaclysmBlacksmithUnrolled *u,
                                                         uint32_t curve);

/**
 * Piece `piece` of curve `curve` on the flat. A new curve; null (and `last_error`) for a null
 * input or an index out of range.
 *
 * # Safety
 * `u` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_unrolled_curve_piece(const struct CadaclysmBlacksmithUnrolled *u,
                                                                                uint32_t curve,
                                                                                uint32_t piece);

/**
 * Point `i` (in the order given to `unroll`) on the flat, into `out` (three doubles).
 * Returns 1 where it landed, 0 where it is on no face laid flat (`out` untouched), -1 (and
 * `last_error`) for a null input or `i` out of range.
 *
 * # Safety
 * `u` live; `out` three doubles.
 */
int32_t cadaclysm_blacksmith_unrolled_point(const struct CadaclysmBlacksmithUnrolled *u,
                                            uint32_t i,
                                            double *out);

/**
 * How many of the faces asked for are not developable (left out). 0 (and `last_error`) for
 * null.
 *
 * # Safety
 * `u` live.
 */
uint32_t cadaclysm_blacksmith_unrolled_not_developable_count(const struct CadaclysmBlacksmithUnrolled *u);

/**
 * The faces not developable, into `out`. `false` (and `last_error`) for a null input.
 *
 * # Safety
 * `u` live; `out` room for `unrolled_not_developable_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_unrolled_not_developable(const struct CadaclysmBlacksmithUnrolled *u,
                                                   uint32_t *out);

/**
 * How many shared edges were cut (their two faces laid apart). 0 (and `last_error`) for null.
 *
 * # Safety
 * `u` live.
 */
uint32_t cadaclysm_blacksmith_unrolled_cut_count(const struct CadaclysmBlacksmithUnrolled *u);

/**
 * The cuts as pairs of source faces, into `out` (two `uint32_t`s a cut). `false` (and
 * `last_error`) for a null input.
 *
 * # Safety
 * `u` live; `out` room for `2 * unrolled_cut_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_unrolled_cuts(const struct CadaclysmBlacksmithUnrolled *u, uint32_t *out);

/**
 * Release an unrolled result. Null is a no-op.
 *
 * # Safety
 * `u` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_unrolled_free(struct CadaclysmBlacksmithUnrolled *u);

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
 * A regular polygon of `sides` (3 to 1024) about (`cx`, `cy`), corner 0 at (`vx`,
 * `vy`), sides kept equal and both construction circles about one centre point:
 * `3 + 2 * sides` ids, `[centre, circumcircle, incircle, corners..., sides...]` (side
 * `k` runs corner `k` to corner `k + 1`); borrowed, `count` set. Dimension either
 * circle to size it. Null on failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_add_polygon(struct CadaclysmBlacksmithSketch *s,
                                                        double cx,
                                                        double cy,
                                                        double vx,
                                                        double vy,
                                                        uint32_t sides,
                                                        size_t *count);

/**
 * Cuts the corner where the lines `a` and `b` meet with a new line, `da` along `a`
 * and `db` along `b` from the corner; the old corner point stays on both lines'
 * extensions as the virtual sharp, dimensioned to the new ends. 6 ids, `[line,
 * point_a, point_b, corner, dimension_a, dimension_b]`; borrowed, `count` set to 6.
 * Null on failure (a distance not shorter than its line, parallel lines, a tangent
 * held at that corner, ...); the sketch is then unchanged.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_chamfer(struct CadaclysmBlacksmithSketch *s,
                                                    uint32_t a,
                                                    uint32_t b,
                                                    double da,
                                                    double db,
                                                    size_t *count);

/**
 * As [`cadaclysm_blacksmith_sketch_chamfer`], with `angle` (radians) the interior
 * angle at the new point on `a` between `a` and the chamfer; `dimension_b` is then
 * that angle (an ANGLE between `a` and the chamfer line). 6 ids, `[line, point_a,
 * point_b, corner, dimension_a, dimension_b]`; borrowed, `count` set to 6. Null on
 * failure.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_chamfer_angle(struct CadaclysmBlacksmithSketch *s,
                                                          uint32_t a,
                                                          uint32_t b,
                                                          double da,
                                                          double angle,
                                                          size_t *count);

/**
 * Copies the `n` entities in `ids` into an `n1` by `n2` grid (both counts include the
 * source) along (`d1x`, `d1y`) and (`d2x`, `d2y`), held by TRANSLATED constraints and
 * driving HORIZONTAL_DISTANCE / VERTICAL_DISTANCE dimensions on the steps. The list is
 * `[k, m, s, d, copies..., steps..., dimensions...]`: `k` copies (the source excluded,
 * row-major, fastest along `d1`) of the `m` = `n` entities, `k * m` ids copy-major
 * (copy `j`'s entity `i` at `4 + j * m + i`), then `s` step ids (0 here), then `d`
 * dimension ids (`dx1, dy1` where `n1 > 1`, then `dx2, dy2` where `n2 > 1`); borrowed,
 * `count` set. Null on failure; the sketch is then unchanged.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `ids` must hold `n` ids; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_pattern_rectangular(struct CadaclysmBlacksmithSketch *s,
                                                                const uint32_t *ids,
                                                                size_t n,
                                                                double d1x,
                                                                double d1y,
                                                                uint32_t n1,
                                                                double d2x,
                                                                double d2y,
                                                                uint32_t n2,
                                                                size_t *count);

/**
 * Copies the `n` entities in `ids` round the point `centre`: `count` instances (the
 * source included), each turned `step` radians counter-clockwise from the last, held
 * by ROTATED constraints, two construction step lines and a driving ANGLE dimension
 * between them. The list is `[k, m, s, d, copies..., steps..., dimensions...]` as for
 * [`cadaclysm_blacksmith_sketch_pattern_rectangular`]: `k = count - 1` copies of `m`
 * = `n` entities, then the `s` = 2 step lines, then the `d` = 1 angle; borrowed,
 * `out_count` set. Null on failure; the sketch is then unchanged.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `ids` must hold `n` ids; `out_count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_pattern_circular(struct CadaclysmBlacksmithSketch *s,
                                                             const uint32_t *ids,
                                                             size_t n,
                                                             uint32_t centre,
                                                             uint32_t count,
                                                             double step,
                                                             size_t *out_count);

/**
 * Mirrors the `n` entities in `ids` across the line `line`: each point reflected (a
 * point on the line is shared, not copied) and held to its source by a SYMMETRIC
 * constraint about `line`, a copied circle by EQUAL_RADIUS to its source, a shared
 * point that is not one of the line's ends by POINT_ON_LINE; construction flags
 * copied; solved. The list is `[copies..., constraints...]`: the `n` copies first, one
 * per entity in `ids` and in its order (for a point on the line, the point itself),
 * then the constraints the call added (the list's length less `n`); borrowed,
 * `out_count` set. Null on failure (`line` not a line, or among the entities); the
 * sketch is then unchanged.
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success.
 *
 * # Safety
 * `s` must be a live sketch; `ids` must hold `n` ids; `out_count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_mirror(struct CadaclysmBlacksmithSketch *s,
                                                   const uint32_t *ids,
                                                   size_t n,
                                                   uint32_t line,
                                                   size_t *out_count);

/**
 * Adds the constraints the geometry already satisfies within `tolerance` (coincident
 * ends, horizontal and vertical lines, tangent joints, parallel, perpendicular,
 * concentric, equal, midpoint, point-on), each kept only where it removes a degree of
 * freedom without a redundancy or conflict; with `dimensions`, driving dimensions at
 * the measured values follow until nothing is free. The new constraint ids,
 * ascending; borrowed, `count` set. Null on failure.
 *
 * `tolerance` 0 or NaN: 1e-6 of the sketch's extent (the diagonal of its points' box).
 *
 * Borrowed: valid until the next call on this sketch or its free; copy it. Never
 * null on success (`count` 0 when empty).
 *
 * # Safety
 * `s` must be a live sketch; `count` null or writable.
 */
const uint32_t *cadaclysm_blacksmith_sketch_auto_constrain(struct CadaclysmBlacksmithSketch *s,
                                                           double tolerance,
                                                           bool dimensions,
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
 * round; LENGTH: line; ANGLE: line, line; RADIUS, DIAMETER: round; SMOOTH: curve,
 * curve; TRANSLATED: point a, point b, from, to; ROTATED: point a, point b, centre,
 * from, to. Dimensions read
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
 * `solve`, `drag`, `add_polygon`, `chamfer`, `chamfer_angle`, `pattern_rectangular`,
 * `pattern_circular`, `mirror` and `auto_constrain` each set it -- the constraints a refusal clashes with or a
 * report names, or the entities holding a point for an in-use refusal; empty when
 * that call named none. Every other call leaves it as it was (the readers, the list
 * readers `entities`, `constraints`, `ends`, `constraint_refs`, `dof_list` and
 * `dof_part_list`, `diagnose`, the other `add_*` calls, the plain setters), so a refusal's
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
 * The `face_count` faces at `faces` of `solid` (none: all) laid flat in the xy plane with the
 * least distortion -- Rhino's `Squisher`. Faces sharing an edge flatten together (unless
 * `explode`); a group of faces that are all developable is laid exactly as `unroll` lays it.
 * `deformation` one of `CADACLYSM_BLACKSMITH_SQUISH_*`; `preserve_boundary` keeps the
 * outline's length. The `curve_count` curves at `curves` follow onto the flat (pieces where
 * they leave the faces), the `point_count` points at `points` (x, y, z triples) to their
 * spots. Null and `last_error` (starting `squish: `) for a face out of range, a bad
 * deformation, and faces that close on themselves (no boundary to open from).
 *
 * # Safety
 * `solid` live; `faces` `face_count` indices; `curves` `curve_count` live curves; `points`
 * `3 * point_count` doubles. Free the result with `cadaclysm_blacksmith_squished_free`.
 */
struct CadaclysmBlacksmithSquished *cadaclysm_blacksmith_squish(const struct CadaclysmBlacksmithSolid *solid,
                                                                const uint32_t *faces,
                                                                size_t face_count,
                                                                const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                size_t curve_count,
                                                                const double *points,
                                                                size_t point_count,
                                                                bool explode,
                                                                uint32_t deformation,
                                                                bool preserve_boundary,
                                                                double tolerance);

/**
 * The flat sheet: an open shell in the xy plane. A new solid; null (and `last_error`) for
 * null.
 *
 * # Safety
 * `q` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_squished_sheet(const struct CadaclysmBlacksmithSquished *q);

/**
 * How many faces the sheet has. 0 (and `last_error`) for null.
 *
 * # Safety
 * `q` live.
 */
uint32_t cadaclysm_blacksmith_squished_face_count(const struct CadaclysmBlacksmithSquished *q);

/**
 * The source face of each sheet face, in the sheet's face order, into `out`. `false` (and
 * `last_error`) for a null input.
 *
 * # Safety
 * `q` live; `out` room for `squished_face_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_squished_faces(const struct CadaclysmBlacksmithSquished *q,
                                         uint32_t *out);

/**
 * Each sheet face's distortion, in the sheet's face order, into `out`: six doubles a face --
 * the flat over 3D area per mesh triangle (min, max, mean weighted by area), then the flat
 * over 3D length per mesh edge (min, max, mean weighted by length). `false` (and
 * `last_error`) for a null input.
 *
 * # Safety
 * `q` live; `out` room for `6 * squished_face_count` doubles.
 */
bool cadaclysm_blacksmith_squished_distortion(const struct CadaclysmBlacksmithSquished *q,
                                              double *out);

/**
 * How many source faces were laid exactly (their group all developable). 0 (and
 * `last_error`) for null.
 *
 * # Safety
 * `q` live.
 */
uint32_t cadaclysm_blacksmith_squished_exact_count(const struct CadaclysmBlacksmithSquished *q);

/**
 * The source faces laid exactly, into `out`. `false` (and `last_error`) for a null input.
 *
 * # Safety
 * `q` live; `out` room for `squished_exact_count` `uint32_t`s.
 */
bool cadaclysm_blacksmith_squished_exact(const struct CadaclysmBlacksmithSquished *q,
                                         uint32_t *out);

/**
 * How many pieces curve `curve` (in the order given to `squish`) came out in: 0 where it
 * missed every face. 0 (and `last_error`) for a null input or a curve out of range.
 *
 * # Safety
 * `q` live.
 */
uint32_t cadaclysm_blacksmith_squished_curve_piece_count(const struct CadaclysmBlacksmithSquished *q,
                                                         uint32_t curve);

/**
 * Piece `piece` of curve `curve` on the flat. A new curve; null (and `last_error`) for a null
 * input or an index out of range.
 *
 * # Safety
 * `q` live.
 */
struct CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_squished_curve_piece(const struct CadaclysmBlacksmithSquished *q,
                                                                                uint32_t curve,
                                                                                uint32_t piece);

/**
 * Point `i` (in the order given to `squish`) on the flat, into `out` (three doubles).
 * Returns 1 where it landed, 0 where it is on no squished face (`out` untouched), -1 (and
 * `last_error`) for a null input or `i` out of range.
 *
 * # Safety
 * `q` live; `out` three doubles.
 */
int32_t cadaclysm_blacksmith_squished_point(const struct CadaclysmBlacksmithSquished *q,
                                            uint32_t i,
                                            double *out);

/**
 * Release a squished result. Null is a no-op.
 *
 * # Safety
 * `q` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_squished_free(struct CadaclysmBlacksmithSquished *q);

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
 * `solid` offset by `distance` -- every face moved along its outward normal, positive outward,
 * negative inward, the faces' new neighbours meeting at sharp joins (OCCT's
 * `BRepOffsetAPI_MakeOffsetShape` by join, intersection mode). A closed solid grows or shrinks
 * to the solid its moved skin bounds; an open sheet moves to its twin, its rims open. Each face
 * keeps the colour, id and attributes of the face it was moved from, however far it moved (its
 * one origin that face); edges are matched by position. A face the offset uses up is gone.
 * Null and `last_error` (prefixed `solid_offset: `) for a distance that is 0, NaN or infinite,
 * a face that folds over (a wall used up), or a skin the offset leaves open.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` null or a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_offset(const struct CadaclysmBlacksmithSolid *solid,
                                                                   double distance,
                                                                   double tolerance);

/**
 * Face `face` of `solid` (an index below [`cadaclysm_blacksmith_face_count`]) alone, as an open
 * sheet moved `distance` along its outward normal, still facing the source's way. A face closed
 * on itself (a sphere's only face) gives a closed solid. Null and `last_error` (prefixed
 * `solid_offset_face: `) for a face the solid has not, a distance that is 0, NaN or infinite, or
 * an offset that folds over.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` null or a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_offset_face(const struct CadaclysmBlacksmithSolid *solid,
                                                                        uint32_t face,
                                                                        double distance,
                                                                        double tolerance);

/**
 * `solid` with its faces split along `count` `curves`, in place: the body stays one body (a
 * closed solid stays closed, a sheet keeps its rim) with more faces, each new face a piece of a
 * face of `solid` on its surface and every new edge the curve itself (OCCT's
 * `BRepFeat_SplitShape`). Curve `i` is laid on face `faces[i]`, which it must lie on, or -- `faces`
 * NULL, or an entry `CADACLYSM_BLACKSMITH_NONE` -- on every face it lies on, only where it does. A
 * curve may run past its face (what lies outside is dropped), cross other curves, and close on
 * itself inside a face (an island); every stretch kept must end on the face's edges or on
 * another curve's end. Both pieces of a split face keep its colour and attributes; the first
 * keeps its id, the others get new ids whose origin is the face. Null and `last_error` (prefixed
 * `split_faces: `) for no curves, a face the solid has not, a curve off its face, a stretch
 * stopping inside a face, a curve through a pole of its face's surface, or no curve crossing
 * any face.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` a live solid; `curves` `count` live curves; `faces` NULL or `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_split_faces(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const uint32_t *faces,
                                                                        const struct CadaclysmBlacksmithNurbsCurve *const *curves,
                                                                        size_t count,
                                                                        double tolerance);

/**
 * `solid` with its faces split along its silhouette seen along (`x`, `y`, `z`) -- a parallel
 * view, looking along that direction: every face the outline runs across is cut there, into the
 * part facing the view and the part facing away, the body still one body with more faces (a
 * mould's parting line for a pull along the direction; Fusion's silhouette split). Exact on
 * planes, cylinders, cones, spheres and tori where the view allows, fitted within `tolerance`
 * elsewhere; a run of the outline along an existing edge is that edge. Colours, ids and
 * attributes as [`cadaclysm_blacksmith_solid_split_faces`]. Null and `last_error` (prefixed
 * `split_along_silhouette: `) for a zero or non-finite direction, an outline through a pole of
 * a face's surface (a sphere seen across its axis), or an outline that crosses no face (a box
 * seen along an axis).
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_split_along_silhouette(const struct CadaclysmBlacksmithSolid *solid,
                                                                                   double x,
                                                                                   double y,
                                                                                   double z,
                                                                                   double tolerance);

/**
 * `solid` with face `face` untrimmed (Fusion's `UntrimFeatures`, Rhino's `RemoveHoles` and
 * `Untrim`, OCCT's `ShapeUpgrade_RemoveInternalWires` for the holes). `which`
 * `CADACLYSM_BLACKSMITH_UNTRIM_HOLES` takes every hole of the face away: a neighbour that
 * shared one of its edges keeps it as a free edge, so a bored solid becomes an open sheet with
 * the bore's walls hanging, and a face with no hole comes back unchanged.
 * `CADACLYSM_BLACKSMITH_UNTRIM_OUTER` replaces the outer boundary by the surface's natural one
 * -- its own parameter domain where it has one, the box of the face's parameters where the
 * surface runs on (a plane, a cylinder's length), the full turn with a seam where the face
 * already wraps round -- the holes kept; `CADACLYSM_BLACKSMITH_UNTRIM_ALL` does both. A side of
 * the new boundary lying on an old edge of the face keeps that edge, so the face stays joined
 * to its neighbour there. Every face keeps its index, colour, id and attributes. Null and
 * `last_error` (prefixed `untrim: `) for another `which`, a face the solid has not, a face
 * with no surface or boundary to read, a natural boundary with no extent, or a kept hole the
 * natural boundary would touch.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_untrim(const struct CadaclysmBlacksmithSolid *solid,
                                                                   uint32_t face,
                                                                   uint32_t which,
                                                                   double tolerance);

/**
 * `solid` taken apart along its edges into bodies (Fusion's `UnstitchFeatures`, Rhino's
 * `UnjoinEdges`; OCCT has no single call): every face kept as it is, the edges between faces
 * of one body still shared, those between bodies left free on each side. `faces` NULL (or
 * `count` 0): every face a one-face sheet of its own. Otherwise, with `together`, the `count`
 * faces listed are one body; without, each listed face is a sheet of its own; either way the
 * faces not listed are one body per edge-connected run of them. The bodies come back side by
 * side in one solid -- the listed ones first, the rest in the order of their first faces --
 * read with [`cadaclysm_blacksmith_lump_count`] and [`cadaclysm_blacksmith_lump`] (listed
 * faces that share no edge with each other read back as a lump each). Every face keeps its
 * colour, id and attributes. Null and `last_error` (prefixed `unstitch: `) for a face the
 * solid has not, or a face listed twice.
 *
 * # Safety
 * `solid` a live solid; `faces` NULL or `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_unstitch(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const uint32_t *faces,
                                                                     size_t count,
                                                                     bool together);

/**
 * A sheet of ruled faces, one off each of `count` `edges` (indices into the list
 * [`cadaclysm_blacksmith_edge`] walks) of `solid` (Fusion's `RuledSurfaceFeatures` from
 * edges; Rhino and OCCT rule between two curves, OCCT's `BRepFill::Face` between the edge and
 * its moved copy): each face runs from the edge `distance` along a ruling of `kind`
 * (`CADACLYSM_BLACKSMITH_RULING_TANGENT`, `_NORMAL`, or `_DIRECTION` along (`x`, `y`, `z`),
 * which other kinds do not read), turned by `angle` radians about the edge -- a positive angle
 * tilts a tangent ruling towards the face's outward normal and a normal ruling back over the
 * face, however the edge's curve runs. A negative `distance` rules the other way. The face the
 * ruling hangs off is the edge's first, its second with `alternate` (a free edge has only
 * one). The far side is exact where the ruling is constant or an affine image of the edge (a
 * line, a direction, an arc or rim circle on a plane, cylinder, cone or sphere), fitted within
 * `tolerance` elsewhere; faces meeting along a side are sewn into one sheet, and corners
 * between edges that are not tangent are left as they fall (no mitre or round). Each ruled
 * face takes the colour and attributes of the face it hangs off; the first off a face keeps
 * that face's id, the others get new ids whose origin is the face. Null and `last_error`
 * (prefixed `ruled_from_edges: `) for no edges, an edge index out of range, another `kind`,
 * a `distance` zero or not finite, an `angle` not finite, a zero or non-finite direction, a
 * ruling along the edge's tangent somewhere, an edge with no exact curve, or a far side that
 * cannot be fitted.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` a live solid; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_ruled_from_edges(const struct CadaclysmBlacksmithSolid *solid,
                                                                             const uint32_t *edges,
                                                                             size_t count,
                                                                             uint32_t kind,
                                                                             double x,
                                                                             double y,
                                                                             double z,
                                                                             double distance,
                                                                             double angle,
                                                                             bool alternate,
                                                                             double tolerance);

/**
 * `solid` with face `face`'s seam moved to `parameter` along `u` (`along_u`) or `v` (Rhino's
 * `Brep.ChangeSeam`; Fusion and OCCT have no such call): the face's surface must close on
 * itself that way and the face go all the way round it, meeting itself along a seam edge.
 * `parameter` is in the face's own parameters, wrapped into the period; a seam already there
 * gives the solid back as it was. The shape, the face count and every other face are
 * unchanged; edges crossing the new seam are cut in two at it. Cylinders, cones, spheres and
 * tori (along `u`; a torus along `v` too) keep their surface, a closed NURBS is reseamed, and
 * a surface of revolution turning a whole turn moves its seam along its spin. Every face keeps
 * its index, colour, id and attributes. Null and `last_error` (prefixed `change_seam: `) for
 * a face the solid has not, a parameter not finite, a surface not closed that way or of a kind
 * whose seam is not moved (an extrusion, a sum, a revolution along its profile), a face with
 * no seam, a hole across the new seam, or a seam that runs through a hole.
 *
 * `tolerance` 0 or NaN: the input's effective tolerance.
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_change_seam(const struct CadaclysmBlacksmithSolid *solid,
                                                                        uint32_t face,
                                                                        bool along_u,
                                                                        double parameter,
                                                                        double tolerance);

/**
 * Two one-face sheets whose faces are untrimmed -- each face bounded by its surface's four
 * sides, as a box's face is -- merged along a side they share into one one-face sheet
 * (Rhino's `Brep.MergeSurfaces`; OCCT's `GeomConvert` concatenates curves only): the two
 * surfaces joined end to end, every point of either a point of the result, the joint left
 * smooth where it already was. The sheet faces as `a`'s face does and takes its colour, id
 * and attributes; `b` is turned as the merge needs. Null and `last_error` (prefixed
 * `merge_surfaces: `) for a body with other than one face, a trimmed face, no side shared
 * within the tolerance, sides that meet only in part, or sides parametrised differently.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance.
 *
 * # Safety
 * `a`, `b` live solids.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_merge_surfaces(const struct CadaclysmBlacksmithSolid *a,
                                                                           const struct CadaclysmBlacksmithSolid *b,
                                                                           double tolerance);

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
 * [`cadaclysm_blacksmith_fillet`] along a chain of spline edges with the radius following a
 * law: `radii[i]` at `shares[i]` of the chain's arc length from its start (0 to 1), run through
 * smoothly by a monotone cubic -- the radius never swings past its stations -- and held flat
 * before the first station and after the last. The `count` edges must run end to end into one
 * open chain, each running on tangent into the next; the chain runs the way `edges[0]`'s curve
 * does. Where the faces either side change from one edge to the next they must meet smooth
 * along a seam through the vertex between. One edge is a chain of one. `tolerance` is the
 * fillet surfaces' fit, as for [`cadaclysm_blacksmith_fillet_varying`].
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `shares` and `radii` `station_count` entries each.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_law(const struct CadaclysmBlacksmithSolid *solid,
                                                                 const uint32_t *edges,
                                                                 size_t count,
                                                                 const double *shares,
                                                                 const double *radii,
                                                                 size_t station_count,
                                                                 double tolerance);

/**
 * [`cadaclysm_blacksmith_fillet`] sized by the chord: the straight distance between the two lines
 * where the round meets its faces, not the radius. Straight edges and partial arcs are rounded
 * together at one radius from each edge's opening angle (picked edges whose faces meet at
 * different angles are refused: one chord gives them different radii); a whole rim against a
 * cylinder, cone, sphere or torus takes its own radius, solved in the rim's meridian plane; spline
 * edges, in a call of their own, are rounded with the ball sized so its rails stand `chord` apart.
 * A box's edge by chord `c` is the fillet of radius `c / sqrt(2)`. `chord` must be positive; a
 * seam among `edges` is skipped.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_chord(const struct CadaclysmBlacksmithSolid *solid,
                                                                   const uint32_t *edges,
                                                                   size_t count,
                                                                   double chord,
                                                                   double tolerance);

/**
 * [`cadaclysm_blacksmith_fillet`] with two set-backs: each picked edge is cut back `distance`
 * along face `face` (which every picked edge must border) and `distance_other` along its other
 * face. The band is the conic tangent to both faces at those lines -- the rolling ball's arc
 * stretched, that arc when the distances agree -- swept along the edge as a rational NURBS.
 * Straight edges between two planes, convex or concave, ending against planes, running on into
 * each other, or meeting at a convex corner whose sections agree. Refused by name: circular and
 * spline edges, an end against a curved face, two fillets meeting where their sections differ.
 * Both distances must be positive; a seam among `edges` is skipped.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_asymmetric(const struct CadaclysmBlacksmithSolid *solid,
                                                                        const uint32_t *edges,
                                                                        size_t count,
                                                                        uint32_t face,
                                                                        double distance,
                                                                        double distance_other,
                                                                        double tolerance);

/**
 * A full round: face `centre` replaced by a round tangent to faces `side` and `other_side`
 * either side of it: a rib's top becomes a half cylinder, a tube's top (a ring between two
 * coaxial walls) a half torus. The radius is solved from the three faces, not given: sides
 * `w` apart give `w / 2`. `centre` must be a plane and each side must share an edge with it.
 * Refused by name: an index past the solid's faces, two sides the same face, a tapered rib, a
 * disc top, curved end faces, side faces lower than the round.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_full_round(const struct CadaclysmBlacksmithSolid *solid,
                                                                        uint32_t side,
                                                                        uint32_t centre,
                                                                        uint32_t other_side,
                                                                        double tolerance);

/**
 * [`cadaclysm_blacksmith_fillet`] at `radius` of the edges a rule picks: with `between_count`
 * 0 every edge with a face in `faces`, otherwise every edge between a face in `faces` and one
 * in `between`; of those, as `rule` says (`CADACLYSM_BLACKSMITH_EDGE_RULE_ALL`, `_CONCAVE`,
 * `_CONVEX`), the convex and/or concave ones, classed at the solid's own angular tolerance.
 * Smooth edges and edges convex along part and concave along another are never picked.
 * Refused by name: no faces, a face index past the solid's faces, a rule outside the three,
 * nothing picked, and every refusal of the fillet itself.
 *
 * `tolerance` 0 or NaN: the inputs' effective tolerance (see
 * [`cadaclysm_blacksmith_effective_tolerance`](crate::cadaclysm_blacksmith_effective_tolerance)).
 *
 * # Safety
 * `solid` live; `faces` `face_count` indices; `between` `between_count` indices (NULL when 0).
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_rule(const struct CadaclysmBlacksmithSolid *solid,
                                                                  const uint32_t *faces,
                                                                  size_t face_count,
                                                                  const uint32_t *between,
                                                                  size_t between_count,
                                                                  uint32_t rule,
                                                                  double radius,
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
