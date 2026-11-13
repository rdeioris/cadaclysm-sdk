//! The kernel's raw C ABI: the structs of `include/cadaclysm_blacksmith.h` in Rust's
//! layout, and every entry point as a function pointer read out of
//! `cadaclysm_blacksmith` when it is loaded -- the kernel's twin of [`crate::sys`].
//!
//! The structs are transcribed by hand and pinned against the header, field by field,
//! by `cadaclysm-capi/tests/bindings.rs`. Everything here is `unsafe` and checks
//! nothing; the safe API is [`crate::blacksmith`].

use std::ffi::{c_char, c_void};
use std::path::{Path, PathBuf};

use crate::loader::entry_points;
#[cfg(not(target_arch = "wasm32"))]
use crate::loader::{Half, Loader};

/// What the kernel returns for "none": no face selected, a count it could not take.
pub const CADACLYSM_BLACKSMITH_NONE: u32 = u32::MAX;

/// `cadaclysm_blacksmith_solid_convert_to_nurbs`'s levels: the procedural surfaces only.
pub const CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL: u32 = 0;
/// Those and the analytic quadrics.
pub const CADACLYSM_BLACKSMITH_NURBS_ANALYTIC: u32 = 1;
/// Every surface and edge curve.
pub const CADACLYSM_BLACKSMITH_NURBS_ALL: u32 = 2;

/// `cadaclysm_blacksmith_hole`'s extents: through everything ahead of the point.
pub const CADACLYSM_BLACKSMITH_HOLE_THROUGH: u32 = 0;
/// `depth` of full bore, then a drill point of `tip_angle`.
pub const CADACLYSM_BLACKSMITH_HOLE_BLIND: u32 = 1;
/// Until the axis first meets face `face`.
pub const CADACLYSM_BLACKSMITH_HOLE_TO_FACE: u32 = 2;
/// Until the bore first leaves the material.
pub const CADACLYSM_BLACKSMITH_HOLE_TO_NEXT: u32 = 3;
/// `cadaclysm_blacksmith_hole`'s heads: none.
pub const CADACLYSM_BLACKSMITH_HOLE_SIMPLE: u32 = 0;
/// A wider bore `head_diameter` across and `head_depth` deep.
pub const CADACLYSM_BLACKSMITH_HOLE_COUNTERBORE: u32 = 1;
/// A cone `head_diameter` across at the point, included angle `head_angle`.
pub const CADACLYSM_BLACKSMITH_HOLE_COUNTERSINK: u32 = 2;
/// `cadaclysm_blacksmith_pattern_feature`'s ops: cut the tool from the body.
pub const CADACLYSM_BLACKSMITH_FEATURE_CUT: u32 = 0;
/// Join the tool to the body.
pub const CADACLYSM_BLACKSMITH_FEATURE_JOIN: u32 = 1;
/// `cadaclysm_blacksmith_rib`'s sides: half the thickness each side of the plane.
pub const CADACLYSM_BLACKSMITH_RIB_BOTH: u32 = 0;
/// The thickness on the plane's +z side.
pub const CADACLYSM_BLACKSMITH_RIB_FRONT: u32 = 1;
/// The thickness on the plane's -z side.
pub const CADACLYSM_BLACKSMITH_RIB_BACK: u32 = 2;
/// `cadaclysm_blacksmith_web`'s sides: half the thickness each side of the curve.
pub const CADACLYSM_BLACKSMITH_WEB_BOTH: u32 = 0;
/// The thickness left of the curve's run, the plane's normal up.
pub const CADACLYSM_BLACKSMITH_WEB_LEFT: u32 = 1;
/// The thickness right of the curve's run.
pub const CADACLYSM_BLACKSMITH_WEB_RIGHT: u32 = 2;
/// `cadaclysm_blacksmith_pattern_along`'s orients: copies translated only.
pub const CADACLYSM_BLACKSMITH_ORIENT_FIXED: u32 = 0;
/// Copies also turned by the curve's rotation-minimising frame.
pub const CADACLYSM_BLACKSMITH_ORIENT_PATH: u32 = 1;

/// The kinds a value array is tagged with (`cadaclysm_blacksmith_value_size` gives each
/// one's length): a line, `from[3] to[3]`.
pub const CADACLYSM_BLACKSMITH_VALUE_LINE: u32 = 0;
/// A circle, `frame[12] radius`.
pub const CADACLYSM_BLACKSMITH_VALUE_CIRCLE: u32 = 1;
/// An arc, `frame[12] radius t0 t1`.
pub const CADACLYSM_BLACKSMITH_VALUE_ARC: u32 = 2;
/// An ellipse, `frame[12] r1 r2`.
pub const CADACLYSM_BLACKSMITH_VALUE_ELLIPSE: u32 = 3;
/// A sphere, `frame[12] radius`.
pub const CADACLYSM_BLACKSMITH_VALUE_SPHERE: u32 = 4;
/// A capped cylinder, `frame[12] radius h0 h1`.
pub const CADACLYSM_BLACKSMITH_VALUE_CYLINDER: u32 = 5;
/// A capped cone, `frame[12] radius height`.
pub const CADACLYSM_BLACKSMITH_VALUE_CONE: u32 = 6;
/// A torus, `frame[12] major minor`.
pub const CADACLYSM_BLACKSMITH_VALUE_TORUS: u32 = 7;
/// A box, `frame[12] x0 x1 y0 y1 z0 z1`.
pub const CADACLYSM_BLACKSMITH_VALUE_CUBOID: u32 = 8;
/// A rectangle, `frame[12] x0 x1 y0 y1`; as a curve its boundary, `t` in 0..4.
pub const CADACLYSM_BLACKSMITH_VALUE_RECTANGLE: u32 = 9;
/// A triangle, `a[3] b[3] c[3]`.
pub const CADACLYSM_BLACKSMITH_VALUE_TRIANGLE: u32 = 10;
/// A ray, `position[3] direction[3]`.
pub const CADACLYSM_BLACKSMITH_VALUE_RAY: u32 = 11;

/// A solid (or open sheet). Opaque; freed with `cadaclysm_blacksmith_solid_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSolid {
    _private: [u8; 0],
}

/// A mutable tree of placements -- a name, and zero or more solids or other assemblies
/// placed in it at a frame. Opaque; freed with `cadaclysm_blacksmith_assembly_free`, which
/// does not free what was placed in it if that is still reachable from somewhere else, as
/// placing shares the placed handle's data rather than copying it.
#[repr(C)]
pub struct CadaclysmBlacksmithAssembly {
    _private: [u8; 0],
}

/// A closed outline with holes, or an open chain. Opaque.
#[repr(C)]
pub struct CadaclysmBlacksmithProfile {
    _private: [u8; 0],
}

/// A 2D outline being drawn. Opaque.
#[repr(C)]
pub struct CadaclysmBlacksmithPath {
    _private: [u8; 0],
}

/// A 3D path a profile is swept along. Opaque.
#[repr(C)]
pub struct CadaclysmBlacksmithSweepPath {
    _private: [u8; 0],
}

#[repr(C)]
pub struct CadaclysmBlacksmithMesh {
    pub positions: *const f32,
    pub normals: *const f32,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
}

/// `CadaclysmBlacksmithMesh` in `double`: the same tessellation (the index pointer is
/// the very one `cadaclysm_blacksmith_mesh` gives), positions and normals unnarrowed.
#[repr(C)]
pub struct CadaclysmBlacksmithMesh64 {
    pub positions: *const f64,
    pub normals: *const f64,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
}

/// A body's mass properties, per unit density, each figure beside a bound on its own error.
///
/// `closed`, `inverted`, `accuracy_met` and `from_mesh` are 1 or 0. The volume, the centroid and the
/// inertia mean something only where `closed` is 1, and are zero otherwise; the area is measured
/// either way. `inertia` is row-major about the centroid with the products of inertia negated,
/// `principal_moments` ascend, and `principal_axes` is row-major, unit and right-handed.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithMassProperties {
    pub closed: i32,
    pub inverted: i32,
    pub accuracy_met: i32,
    pub from_mesh: i32,
    pub area: f64,
    pub area_error: f64,
    pub volume: f64,
    pub volume_error: f64,
    pub centroid: [f64; 3],
    pub centroid_error: f64,
    pub inertia: [f64; 9],
    pub inertia_error: f64,
    pub principal_moments: [f64; 3],
    pub principal_axes: [f64; 9],
}

/// A solid's box on its principal axes (`cadaclysm_blacksmith_oriented_box`). `axes` is
/// row-major, row `i` the direction of the extent `half[i]`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithOrientedBox {
    pub centre: [f64; 3],
    pub axes: [f64; 9],
    pub half: [f64; 3],
}

/// A measured length beside its error; the two ints are 1 or 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithLength {
    pub length: f64,
    pub error: f64,
    pub accuracy_met: i32,
    pub from_polyline: i32,
}

/// The closest points between two solids' boundaries. `kind_*` are static strings the library
/// owns (never freed); `edge_*` is `u32::MAX` where there is no fillet-table edge.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithClosest {
    pub distance: f64,
    pub on_a: [f64; 3],
    pub on_b: [f64; 3],
    pub kind_a: *const c_char,
    pub index_a: u32,
    pub edge_a: u32,
    pub kind_b: *const c_char,
    pub index_b: u32,
    pub edge_b: u32,
    pub refined: i32,
}

/// The nearest point of a solid (or of one face) to a query point. `kind` is a static string the
/// library owns (never freed); `edge` is `u32::MAX` where there is no edge-table row; `uv` is NaN
/// off a face.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithPointFoot {
    pub distance: f64,
    pub point: [f64; 3],
    pub kind: *const c_char,
    pub index: u32,
    pub edge: u32,
    pub uv: [f64; 2],
    pub normal: [f64; 3],
    pub refined: i32,
}

/// The nearest points of two curves: side `a` the curve asked, side `b` the other.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithCurvePair {
    pub distance: f64,
    pub t_a: f64,
    pub point_a: [f64; 3],
    pub t_b: f64,
    pub point_b: [f64; 3],
}

/// The nearest points of a curve and a solid's boundary: the curve's side, then the body's as a
/// point foot; `crossing` 1 where the curve passes through the boundary.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithCurveBodyFoot {
    pub distance: f64,
    pub t: f64,
    pub point_on_curve: [f64; 3],
    pub body: CadaclysmBlacksmithPointFoot,
    pub crossing: i32,
}

/// The nearest point of a triangle mesh: `kind` 0 face, 1 edge, 2 vertex; an unused `vertices`
/// slot is `u32::MAX`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithMeshPoint {
    pub point: [f64; 3],
    pub distance: f64,
    pub triangle: u32,
    pub kind: u32,
    pub barycentric: [f64; 3],
    pub vertices: [u32; 2],
}

/// The nearest points of a curve and a triangle mesh: the curve's side, then the mesh's as a mesh
/// point; `crossing` 1 where the curve passes through the mesh.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithCurveMeshFoot {
    pub distance: f64,
    pub t: f64,
    pub point_on_curve: [f64; 3],
    pub mesh: CadaclysmBlacksmithMeshPoint,
    pub crossing: i32,
}

/// The nearest item of a set to a curve. Only the member `answer_kind` names is filled (0
/// `body`, 1 `pair`, 2 neither, 3 `mesh`); every byte of the others is zero, a `kind` null. C
/// writes the whole struct, `mesh` included.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithNearestObject {
    pub which: u32,
    pub answer_kind: i32,
    pub distance: f64,
    pub t: f64,
    pub point_on_curve: [f64; 3],
    pub point_on_item: [f64; 3],
    pub body: CadaclysmBlacksmithCurveBodyFoot,
    pub pair: CadaclysmBlacksmithCurvePair,
    pub mesh: CadaclysmBlacksmithCurveMeshFoot,
}

/// One sample of an arc-length read (`cadaclysm_blacksmith_edge_point_at_length` and the
/// divides); `segment` is `u32::MAX` on a solid's edge.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithAt {
    pub point: [f64; 3],
    pub tangent: [f64; 3],
    pub parameter: f64,
    pub segment: u32,
    pub error: f64,
    pub from_polyline: i32,
}

/// A curve's bending at a parameter (`cadaclysm_blacksmith_nurbs_curve_curvature`): `kappa`
/// (1 / radius), the unit tangent, the unit normal toward the centre, the binormal and the
/// centre of the osculating circle. On a straight piece `kappa` is 0, `normal` and `binormal`
/// are zero and `has_centre` is 0.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithCurvature {
    pub kappa: f64,
    pub tangent: [f64; 3],
    pub normal: [f64; 3],
    pub binormal: [f64; 3],
    pub centre: [f64; 3],
    pub has_centre: i32,
}

/// How well two faces meet along their sides (`cadaclysm_blacksmith_continuity`): the largest
/// gap, the largest angle between the normals and the largest curvature difference, each with
/// where it was found, and how many points were asked.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithContinuity {
    pub gap: f64,
    pub gap_at: [f64; 3],
    pub angle: f64,
    pub angle_at: [f64; 3],
    pub curvature: f64,
    pub curvature_at: [f64; 3],
    pub samples: u32,
}

/// How smoothly a curve runs through its own knots (`cadaclysm_blacksmith_nurbs_curve_knot_continuity`):
/// the largest turn of its tangent in radians and jump of its curvature vector, each with the
/// parameter and the point it was found at.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithKnotContinuity {
    pub angle: f64,
    pub angle_parameter: f64,
    pub angle_at: [f64; 3],
    pub curvature: f64,
    pub curvature_parameter: f64,
    pub curvature_at: [f64; 3],
}

/// Where a face's Gaussian and mean curvature change sign (`cadaclysm_blacksmith_curvature_turns`):
/// how many separate areas of each sign the sample grid finds for each, how many points it found
/// between opposite signs, and the grid's steps each way.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithCurvatureTurns {
    pub gaussian_positive: u32,
    pub gaussian_negative: u32,
    pub gaussian_turns: u32,
    pub mean_positive: u32,
    pub mean_negative: u32,
    pub mean_turns: u32,
    pub samples: u32,
}

/// The worst kink of the highlight lines crossing an edge (`cadaclysm_blacksmith_highlight_kink`):
/// the angle, where along the edge, the light tube that shows it and how many points were read.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithHighlightKink {
    pub angle: f64,
    pub at: [f64; 3],
    pub light_point: [f64; 3],
    pub light_direction: [f64; 3],
    pub samples: u32,
}

/// One side of the hole `cadaclysm_blacksmith_n_sided_patch` fills: a sheet's side, or (where
/// `sheet` is NULL) a curve met at G0.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithPatchBoundary {
    pub sheet: *const CadaclysmBlacksmithSolid,
    pub face: u32,
    pub side: u32,
    pub from: f64,
    pub to: f64,
    pub level: u32,
    pub curve: *const CadaclysmBlacksmithNurbsCurve,
}

/// How well an N-sided patch meets (`cadaclysm_blacksmith_n_sided_patch`'s `report_out`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithPatchReport {
    pub faces: u32,
    pub boundary: CadaclysmBlacksmithContinuity,
    pub internal: CadaclysmBlacksmithContinuity,
    pub corner_angle: f64,
}

/// What `cadaclysm_blacksmith_join_sheets` did.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithJoinReport {
    pub sewn: u32,
    pub naked_before: u32,
    pub naked_after: u32,
    pub refused: u32,
    pub turned: u32,
    pub worst_gap: f64,
    pub closed: i32,
}

/// A curve in space, always a NURBS. Opaque, immutable; freed with
/// `cadaclysm_blacksmith_nurbs_curve_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithNurbsCurve {
    _private: [u8; 0],
}

/// The samples of one divide call. Opaque; read with `cadaclysm_blacksmith_samples_at`,
/// freed with `cadaclysm_blacksmith_samples_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSamples {
    _private: [u8; 0],
}

/// A reusable point-in-body classifier. Opaque; freed with `cadaclysm_blacksmith_classifier_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithClassifier {
    _private: [u8; 0],
}

/// A reusable nearest-point search. Opaque; freed with `cadaclysm_blacksmith_projector_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithProjector {
    _private: [u8; 0],
}

/// An exact triangle mesh and its search tree. Opaque; freed with
/// `cadaclysm_blacksmith_triangle_mesh_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithTriangleMesh {
    _private: [u8; 0],
}

/// A hidden-line view of solids or meshes, from `cadaclysm_blacksmith_hlr` /
/// `cadaclysm_blacksmith_hlr_mesh`. Opaque; freed with `cadaclysm_blacksmith_hlr_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithHlr {
    _private: [u8; 0],
}

/// A flat drawing page, from `cadaclysm_blacksmith_page_new`. Opaque; freed with
/// `cadaclysm_blacksmith_page_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithPage {
    _private: [u8; 0],
}

/// How the solids are seen and what is drawn (`cadaclysm_blacksmith_hlr_options_init` fills
/// it). `projection` 0 parallel (`direction`, `up`), 1 perspective (`eye`, `target`, `up`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CadaclysmBlacksmithHlrOptions {
    pub size: u32,
    pub projection: u32,
    pub direction: [f64; 3],
    pub up: [f64; 3],
    pub eye: [f64; 3],
    pub target: [f64; 3],
    pub tolerance: f64,
    pub smooth_angle: f64,
    pub feature_angle: f64,
    pub iso: u32,
    pub reserved: u32,
}

/// One line of a hidden-line view (`cadaclysm_blacksmith_hlr_line`): its kind, whether it is
/// seen, its solid, what it is a span of, and how many Béziers draw it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CadaclysmBlacksmithHlrLine {
    pub kind: u32,
    pub visible: u32,
    pub solid: u32,
    pub source_kind: u32,
    pub source: u32,
    pub source2: u32,
    pub bezier_count: u32,
    pub reserved: u32,
    pub length2d: f64,
    pub length3d: f64,
}

/// What a view's hidden-line removal did (`cadaclysm_blacksmith_hlr_report`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CadaclysmBlacksmithHlrReport {
    pub candidates: u32,
    pub segments: u32,
    pub crossings: u32,
    pub pieces: u32,
    pub degenerate: u32,
    pub rays: u32,
    pub mesh_hits: u32,
    pub rejected: u32,
    pub grazes: u32,
    pub unsettled: u32,
    pub mesh_only: u32,
    pub fallback_edges: u32,
    pub failed_solids: u32,
    pub reserved: u32,
    pub candidate_length: f64,
    pub degenerate_length: f64,
    pub tolerance: f64,
}

/// One answer of an R-tree search, `within` or `nearest`: the entry's id and the distance from
/// the query point to its box (0 inside it, and 0 for every search hit).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithRTreeHit {
    pub id: u32,
    pub distance: f64,
}

/// One overlapping pair of R-tree entry ids (`a` from the first tree for `rtree_overlaps`,
/// `a <= b` for `rtree_self_overlaps`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithRTreePair {
    pub a: u32,
    pub b: u32,
}

/// An R*-tree over boxes with ids. Opaque; freed with `cadaclysm_blacksmith_rtree_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithRTree {
    _private: [u8; 0],
}

/// The hits of one R-tree query. Opaque; read with `cadaclysm_blacksmith_rtree_hits_at`, freed
/// with `cadaclysm_blacksmith_rtree_hits_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithRTreeHits {
    _private: [u8; 0],
}

/// The pairs of one R-tree overlap query. Opaque; read with `cadaclysm_blacksmith_rtree_pairs_at`,
/// freed with `cadaclysm_blacksmith_rtree_pairs_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithRTreePairs {
    _private: [u8; 0],
}

/// The interpolator modes, `CADACLYSM_BLACKSMITH_INTERPOLATE_*`: the sample at `floor(t + 1/2)`.
pub const CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST: u32 = 0;
/// Straight between neighbouring samples.
pub const CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR: u32 = 1;
/// Linear on a cosine ease, flat at every sample.
pub const CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE: u32 = 2;
/// Bourke's cubic through every sample.
pub const CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC: u32 = 3;
/// Catmull-Rom: through every sample, C1.
pub const CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM: u32 = 4;

/// Samples read at a fractional index. Opaque and immutable; freed with
/// `cadaclysm_blacksmith_interpolator_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithInterpolator {
    _private: [u8; 0],
}

/// A solid's regions, region 0 first. Opaque and immutable; read with
/// `cadaclysm_blacksmith_regions_at` / `_side_at`, freed with `cadaclysm_blacksmith_regions_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithRegions {
    _private: [u8; 0],
}

/// One region of a solid: `finite` 0 for region 0, the infinite one, 1 for every other; `min` /
/// `max` the box round the faces bounding it; `sides` how many face sides bound it; `shells` 1
/// plus one per void inside it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithRegion {
    pub finite: i32,
    pub min: [f64; 3],
    pub max: [f64; 3],
    pub sides: u32,
    pub shells: u32,
}

/// One side of one face bounding a region: the face's index and `sense` +1 where the region is
/// the side the face's normal points to, -1 the other.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithFaceSide {
    pub face: u32,
    pub sense: i32,
}

#[repr(C)]
pub struct CadaclysmBlacksmithPolylines {
    pub points: *const f32,
    /// `polyline_count + 1` entries; the last equals `point_count`.
    pub offsets: *const u32,
    pub point_count: u32,
    pub polyline_count: u32,
}

/// One colour per edge polyline (`cadaclysm_blacksmith_edge_polyline_colours`): three
/// doubles each, `-1` where the polyline is on no coloured edge; `rgb` null and `count` 0
/// where the solid has no edge paint.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithColours {
    pub rgb: *const f64,
    pub count: u32,
}

/// Triangles per face, in face order, over the mesh at the same tolerance.
#[repr(C)]
pub struct CadaclysmBlacksmithFaceTriangles {
    pub counts: *const u32,
    pub face_count: u32,
}

#[repr(C)]
pub struct CadaclysmBlacksmithEdge {
    pub kind: *const c_char,
    pub faces: *const u32,
    pub face_count: u32,
    /// Six doubles a segment: its two ends.
    pub segments: *const f64,
    pub segment_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithPoint {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

/// On a profile: `loop_index`, `segment` and `t`, with `face` NONE. On a solid's face:
/// `face` and its (`u`, `v`), with `loop_index` and `segment` NONE.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithSpot {
    pub loop_index: u32,
    pub segment: u32,
    pub t: f64,
    pub face: u32,
    pub u: f64,
    pub v: f64,
}

/// One hit, copied out by `cadaclysm_blacksmith_hit`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithHit {
    pub run: bool,
    pub touch: bool,
    pub start: CadaclysmBlacksmithPoint,
    pub end: CadaclysmBlacksmithPoint,
    pub a_start: CadaclysmBlacksmithSpot,
    pub a_end: CadaclysmBlacksmithSpot,
    pub b_start: CadaclysmBlacksmithSpot,
    pub b_end: CadaclysmBlacksmithSpot,
}

/// One edge's exact curve, borrowed from its solid (`cadaclysm_blacksmith_edge_curve`):
/// `knots`/`poles`/`weights` are null with zero counts where the kind has none.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithCurve {
    pub kind: *const c_char,
    pub origin: CadaclysmBlacksmithPoint,
    pub x: CadaclysmBlacksmithPoint,
    pub y: CadaclysmBlacksmithPoint,
    pub z: CadaclysmBlacksmithPoint,
    pub radius: f64,
    pub radius2: f64,
    pub t0: f64,
    pub t1: f64,
    pub degree: u32,
    pub knots: *const f64,
    pub knot_count: u32,
    /// Three doubles a control point.
    pub poles: *const f64,
    pub pole_count: u32,
    pub weights: *const f64,
}

impl Default for CadaclysmBlacksmithCurve {
    fn default() -> Self {
        CadaclysmBlacksmithCurve {
            kind: std::ptr::null(),
            origin: Default::default(),
            x: Default::default(),
            y: Default::default(),
            z: Default::default(),
            radius: 0.0,
            radius2: 0.0,
            t0: 0.0,
            t1: 0.0,
            degree: 0,
            knots: std::ptr::null(),
            knot_count: 0,
            poles: std::ptr::null(),
            pole_count: 0,
            weights: std::ptr::null(),
        }
    }
}

/// One branch of one face pair's crossing, borrowed from an intersection result
/// (`cadaclysm_blacksmith_intersection_chain`): `points` is `point_count` xyz triples.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithChain {
    pub points: *const f64,
    pub point_count: u32,
    pub face_a: u32,
    pub face_b: u32,
    pub closed: bool,
    pub tangent: bool,
    pub has_curve: bool,
}

impl Default for CadaclysmBlacksmithChain {
    fn default() -> Self {
        CadaclysmBlacksmithChain { points: std::ptr::null(), point_count: 0, face_a: 0, face_b: 0, closed: false, tangent: false, has_curve: false }
    }
}

/// A coincident face pair's shared region, borrowed from an intersection result
/// (`cadaclysm_blacksmith_intersection_overlap`): `points` is `point_count` xyz triples,
/// every ring back to back; `loop_offsets` is `loop_count` ring starts counted in points.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithOverlap {
    pub face_a: u32,
    pub face_b: u32,
    pub points: *const f64,
    pub loop_offsets: *const u32,
    pub point_count: u32,
    pub loop_count: u32,
}

impl Default for CadaclysmBlacksmithOverlap {
    fn default() -> Self {
        CadaclysmBlacksmithOverlap { face_a: 0, face_b: 0, points: std::ptr::null(), loop_offsets: std::ptr::null(), point_count: 0, loop_count: 0 }
    }
}

/// One thing wrong with one argument, copied out of a check result
/// (`cadaclysm_blacksmith_check_finding`): `kind` a static string, `argument` 0 or 1, and
/// `index`/`other` `CADACLYSM_BLACKSMITH_NONE` and `size` 0 where the kind gives none.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithFinding {
    pub kind: *const c_char,
    pub argument: u32,
    pub index: u32,
    pub other: u32,
    pub size: f64,
}

impl Default for CadaclysmBlacksmithFinding {
    fn default() -> Self {
        CadaclysmBlacksmithFinding { kind: std::ptr::null(), argument: 0, index: 0, other: 0, size: 0.0 }
    }
}

/// The crossing of two solids, from `cadaclysm_blacksmith_intersect`. Opaque; freed with
/// `cadaclysm_blacksmith_intersection_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithIntersection {
    _private: [u8; 0],
}

/// An argument check's findings, from `cadaclysm_blacksmith_check`. Opaque; freed with
/// `cadaclysm_blacksmith_check_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithCheck {
    _private: [u8; 0],
}

/// Parts meshed once, asked pose after pose which of them interfere. Opaque; freed
/// with `cadaclysm_blacksmith_collider_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithCollider {
    _private: [u8; 0],
}

/// One `cadaclysm_blacksmith_collider_check` call's answer, read one pair at a time
/// (`cadaclysm_blacksmith_collisions_hit`) or rebuilt exactly
/// (`cadaclysm_blacksmith_collisions_solid`). Opaque; freed with
/// `cadaclysm_blacksmith_collisions_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithCollisions {
    _private: [u8; 0],
}

/// One `cadaclysm_blacksmith_collider_clash` or `cadaclysm_blacksmith_clash` call's answer,
/// read one pair at a time (`cadaclysm_blacksmith_clashes_at`) or rebuilt
/// (`cadaclysm_blacksmith_clashes_solid`, `cadaclysm_blacksmith_clashes_intersect`). Opaque,
/// immutable; freed with `cadaclysm_blacksmith_clashes_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithClashes {
    _private: [u8; 0],
}

/// One `cadaclysm_blacksmith_collider_swept_clash` or `cadaclysm_blacksmith_swept_clash`
/// call's answer, read one pair at a time (`cadaclysm_blacksmith_swept_clashes_at`,
/// `cadaclysm_blacksmith_swept_clashes_interval`), its first rows a clashes list of their own
/// (`cadaclysm_blacksmith_swept_clashes_firsts`). Opaque, immutable; freed with
/// `cadaclysm_blacksmith_swept_clashes_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSweptClashes {
    _private: [u8; 0],
}

/// Solids meshed once for wall thickness (`cadaclysm_blacksmith_thickness_gauge_new`). Opaque;
/// freed with `cadaclysm_blacksmith_thickness_gauge_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithThicknessGauge {
    _private: [u8; 0],
}

/// The readings one gauge call made (`cadaclysm_blacksmith_thickness_gauge_measure`, `_at`).
/// Opaque, immutable; freed with `cadaclysm_blacksmith_thicknesses_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithThicknesses {
    _private: [u8; 0],
}

/// The readings one `cadaclysm_blacksmith_mesh_thickness` call made. Opaque, immutable; freed
/// with `cadaclysm_blacksmith_mesh_thicknesses_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithMeshThicknesses {
    _private: [u8; 0],
}

/// A solid's health report (`cadaclysm_blacksmith_health`): owned rows, independent of the
/// solid. Opaque; freed with `cadaclysm_blacksmith_health_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithHealth {
    _private: [u8; 0],
}

/// A heal report and the healed solid (`cadaclysm_blacksmith_healed`): owned, independent of
/// the solid. Opaque; freed with `cadaclysm_blacksmith_heal_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithHeal {
    _private: [u8; 0],
}

/// What a verb did to its inputs' faces (or edges), read off the result's ids alone
/// (`cadaclysm_blacksmith_history`). Opaque; freed with `cadaclysm_blacksmith_history_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithHistory {
    _private: [u8; 0],
}

/// A SubD control cage. Opaque; freed with `cadaclysm_blacksmith_subd_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSubd {
    _private: [u8; 0],
}

/// A 2D constraint sketch. Opaque; freed with `cadaclysm_blacksmith_sketch_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSketch {
    _private: [u8; 0],
}

/// A cage's parts, as views into its handle: valid until the handle is freed.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithSubdParts {
    pub positions: *const f64,
    pub vertex_count: u32,
    pub face_sizes: *const u32,
    pub face_count: u32,
    pub face_indices: *const u32,
    pub index_count: u32,
    pub creases: *const u32,
    pub crease_count: u32,
    pub pins: *const u32,
    pub pin_count: u32,
    pub symmetry_axis: i32,
    pub symmetry_tolerance: f64,
    pub selection_kind: u32,
    pub selection: *const u32,
    pub selection_count: u32,
}

impl Default for CadaclysmBlacksmithSubdParts {
    fn default() -> Self {
        let none = std::ptr::null();
        CadaclysmBlacksmithSubdParts {
            positions: none as *const f64,
            vertex_count: 0,
            face_sizes: none,
            face_count: 0,
            face_indices: none,
            index_count: 0,
            creases: none,
            crease_count: 0,
            pins: none,
            pin_count: 0,
            symmetry_axis: -1,
            symmetry_tolerance: 0.0,
            selection_kind: 3,
            selection: none,
            selection_count: 0,
        }
    }
}

/// A cage's smooth surface at one level, as views valid until the handle is freed.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithSubdMesh {
    pub positions: *const f64,
    pub vertex_count: u32,
    pub normals: *const f64,
    pub indices: *const u32,
    pub index_count: u32,
    pub triangle_face: *const u32,
}

impl Default for CadaclysmBlacksmithSubdMesh {
    fn default() -> Self {
        CadaclysmBlacksmithSubdMesh {
            positions: std::ptr::null(),
            vertex_count: 0,
            normals: std::ptr::null(),
            indices: std::ptr::null(),
            index_count: 0,
            triangle_face: std::ptr::null(),
        }
    }
}

/// What `cadaclysm_blacksmith_subd_to_solid` did and how close it came.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithSubdReport {
    pub regular: u32,
    pub refined: u32,
    pub steps: u32,
    pub levels: u32,
    pub deviation: f64,
    pub g1_angle_deg: f64,
    pub deviation_at: [f64; 3],
    pub g1_at: [f64; 3],
}

/// An axis-aligned box: `lo` and `hi`, three doubles each.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithBox {
    pub lo: [f64; 3],
    pub hi: [f64; 3],
}

/// Counts of one `cadaclysm_blacksmith_collider_check` call: the candidate pairs
/// `considered`, how many the world boxes and the oriented boxes cleared, how many
/// the share left to another call, how the rest were answered (`cached`,
/// `closed_form`, `meshed`), and how many were `refused`. `confirmed` is the subset
/// of `meshed` that were thin mesh-path overlaps sent to `common` for a final answer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithColliderStats {
    pub considered: u32,
    pub world_boxes: u32,
    pub oriented_boxes: u32,
    pub skipped_share: u32,
    pub cached: u32,
    pub closed_form: u32,
    pub meshed: u32,
    pub refused: u32,
    pub confirmed: u32,
}

/// A pair that interferes (`overlap` true), or could not be decided (`overlap`
/// false; `text` says why, empty for an overlap). `positions` and `normals` are
/// `vertex_count` world xyz triples, three per triangle (unwelded); `indices` is
/// `index_count` entries; all empty (null, counts 0) for a refused pair. `depth` is
/// the thinnest side of the overlap's world box, 0 for a refused pair.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithCollisionHit {
    pub a: u32,
    pub b: u32,
    pub overlap: bool,
    pub depth: f64,
    pub positions: *const f64,
    pub normals: *const f64,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
    pub text: *const c_char,
}

impl Default for CadaclysmBlacksmithCollisionHit {
    fn default() -> Self {
        CadaclysmBlacksmithCollisionHit {
            a: 0,
            b: 0,
            overlap: false,
            depth: 0.0,
            positions: std::ptr::null(),
            normals: std::ptr::null(),
            indices: std::ptr::null(),
            vertex_count: 0,
            index_count: 0,
            text: std::ptr::null(),
        }
    }
}

/// A pair that penetrates, touches, lies within the clearance, or could not be decided. Every
/// string borrows from the clashes handle (valid until it is freed); `kind_*` read as
/// [`CadaclysmBlacksmithClosest`]'s, `"none"` (index 0, edge `u32::MAX`) for a penetrating or
/// refused pair; `edge_*` is `u32::MAX` where there is no fillet-table edge.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithClash {
    pub a: u32,
    pub b: u32,
    pub kind: *const c_char,
    pub distance: f64,
    pub on_a: [f64; 3],
    pub on_b: [f64; 3],
    pub kind_a: *const c_char,
    pub index_a: u32,
    pub edge_a: u32,
    pub kind_b: *const c_char,
    pub index_b: u32,
    pub edge_b: u32,
    pub refined: i32,
    pub depth: f64,
    pub text: *const c_char,
}

impl Default for CadaclysmBlacksmithClash {
    fn default() -> Self {
        CadaclysmBlacksmithClash {
            a: 0,
            b: 0,
            kind: std::ptr::null(),
            distance: 0.0,
            on_a: [0.0; 3],
            on_b: [0.0; 3],
            kind_a: std::ptr::null(),
            index_a: 0,
            edge_a: u32::MAX,
            kind_b: std::ptr::null(),
            index_b: 0,
            edge_b: u32::MAX,
            refined: 0,
            depth: 0.0,
            text: std::ptr::null(),
        }
    }
}

/// One pair a swept clash call found: `a`, `b` the part indices (as [`CadaclysmBlacksmithClash`]'s),
/// `first_time` the first time the pair came within the clearance, in pose units (for a
/// refused pair, the time it was refused at), `interval_count` how many time ranges it stays
/// in clash (0 for a refused pair). The pose-wise row at `first_time` is row `i` of
/// `cadaclysm_blacksmith_swept_clashes_firsts`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithSweptClash {
    pub a: u32,
    pub b: u32,
    pub first_time: f64,
    pub interval_count: u32,
}

/// `CadaclysmBlacksmithThickness`: one wall-thickness reading on a solid. `vertex` is
/// [`CADACLYSM_BLACKSMITH_NONE`] for a reading at a point; `sphere` is NaN for none.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithThickness {
    pub body: u32,
    pub vertex: u32,
    pub face: u32,
    pub point: [f64; 3],
    pub thickness: f64,
    pub opposite: [f64; 3],
    pub opposite_body: u32,
    pub opposite_face: u32,
    pub knife: bool,
    pub exact_thickness: f64,
    pub exact_opposite: [f64; 3],
    pub sphere: f64,
}

/// `CadaclysmBlacksmithMeshThickness`: one reading on a plain mesh.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithMeshThickness {
    pub mesh: u32,
    pub vertex: u32,
    pub thickness: f64,
    pub point: [f64; 3],
    pub opposite: [f64; 3],
    pub opposite_mesh: u32,
    pub opposite_triangle: u32,
    pub knife: bool,
}

/// `CadaclysmBlacksmithFaceThickness`: one thickness for a face. `found` false: the numbers
/// are NaN.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct CadaclysmBlacksmithFaceThickness {
    pub found: bool,
    pub thickness: f64,
    pub min: f64,
    pub max: f64,
    pub uniform: bool,
}

/// `CadaclysmBlacksmithThicknessMesh`: a gauge body's measuring mesh. Every pointer borrows
/// from the gauge (valid until it is freed); copy out before then.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CadaclysmBlacksmithThicknessMesh {
    pub positions: *const f64,
    pub normals: *const f64,
    pub indices: *const u32,
    pub faces: *const u32,
    pub vertex_count: u32,
    pub triangle_count: u32,
}

impl Default for CadaclysmBlacksmithThicknessMesh {
    fn default() -> Self {
        CadaclysmBlacksmithThicknessMesh {
            positions: std::ptr::null(),
            normals: std::ptr::null(),
            indices: std::ptr::null(),
            faces: std::ptr::null(),
            vertex_count: 0,
            triangle_count: 0,
        }
    }
}

/// `CadaclysmBlacksmithSvgOptions`. `size` is the struct's growth room, as
/// `CadaclysmOpenOptions` on the reader library -- this crate fills it by calling
/// `cadaclysm_blacksmith_svg_options_init` first, then overrides the fields
/// [`crate::blacksmith::SvgOptions`] carries.
#[repr(C)]
pub struct CadaclysmBlacksmithSvgOptions {
    pub size: u32,
    pub up: u32,
    pub azimuth: f64,
    pub elevation: f64,
    pub fov: f64,
    pub width: f64,
    pub height: f64,
    pub margin: f64,
    pub tolerance: f64,
    pub stroke_width: f64,
    pub stroke: u32,
    pub background: u32,
    pub flags: u32,
}

/// The hits of one `cadaclysm_blacksmith_profile_hits` call. Opaque; freed with
/// `cadaclysm_blacksmith_hits_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithHits {
    _private: [u8; 0],
}

/// The profiles of one `cadaclysm_blacksmith_profile_common` call. Opaque; read with
/// `cadaclysm_blacksmith_profile_list_get`, freed with `cadaclysm_blacksmith_profile_list_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithProfileList {
    _private: [u8; 0],
}

/// A cutter. Opaque; freed with `cadaclysm_blacksmith_tool_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithTool {
    _private: [u8; 0],
}

/// A block of material a job cuts. Opaque; freed with `cadaclysm_blacksmith_stock_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithStock {
    _private: [u8; 0],
}

/// A machining job on a stock. Opaque; freed with `cadaclysm_blacksmith_job_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithJob {
    _private: [u8; 0],
}

/// The files of one `cadaclysm_blacksmith_job_gcode`/`cadaclysm_blacksmith_job_camotics` call.
/// Opaque; read with the `cadaclysm_blacksmith_programs_*` accessors, freed with
/// `cadaclysm_blacksmith_programs_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithPrograms {
    _private: [u8; 0],
}

/// What one `cadaclysm_blacksmith_job_machine` call left uncut. Opaque; read with the
/// `cadaclysm_blacksmith_report_*` accessors, freed with `cadaclysm_blacksmith_report_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithReport {
    _private: [u8; 0],
}

/// Every operation added to a job, from `cadaclysm_blacksmith_job_operations`. Opaque; read
/// with the `cadaclysm_blacksmith_operations_*` accessors, freed with
/// `cadaclysm_blacksmith_operations_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithOperations {
    _private: [u8; 0],
}

/// One meshed tessellation of a solid, held independently of it. Opaque: owned, made with
/// `cadaclysm_blacksmith_tessellation`, freed with `cadaclysm_blacksmith_tessellation_free`.
/// The accessors' pointers borrow from **this handle**, not the solid, and stay valid until
/// it is freed -- whatever happens to the solid meanwhile: re-meshed at any tolerance,
/// freed itself. The Rust SDK's own API stays borrow-checked (`&mut self`); this struct and
/// its six entry points exist only so `sys.rs` matches the header for the parity gate.
#[repr(C)]
pub struct CadaclysmBlacksmithTessellation {
    _private: [u8; 0],
}

/// One solid meshed for a solver. Opaque: owned, and freed with
/// `cadaclysm_blacksmith_fem_mesh_free`. Every pointer any accessor writes is borrowed
/// from it -- **except** the `.msh` text, which is the caller's and is released with
/// `cadaclysm_blacksmith_string_free`, where the reader library's is a borrowed slot on
/// its own handle.
#[repr(C)]
pub struct CadaclysmBlacksmithFemMesh {
    _private: [u8; 0],
}

/// `CadaclysmBlacksmithFemOptions`, the kernel's twin of `CadaclysmFemOptions`: `size` is
/// the struct's growth room, filled by `cadaclysm_blacksmith_fem_options_init` as
/// `CadaclysmBlacksmithSvgOptions` is filled by its own init.
#[repr(C)]
pub struct CadaclysmBlacksmithFemOptions {
    pub size: usize,
    pub tolerance: f64,
    pub max_size: f64,
}

/// `CadaclysmBlacksmithFemMeshView`: the flat arrays of one FEM mesh and its summary, every
/// pointer borrowed from the handle and read once when it is made.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmBlacksmithFemMeshView {
    pub nodes: *const f64,
    pub node_count: u32,
    pub triangles: *const u32,
    pub triangle_count: u32,
    pub triangle_face: *const u32,
    pub node_kind: *const u32,
    pub node_entity: *const u32,
    pub face_count: u32,
    pub edge_count: u32,
    pub vertex_count: u32,
    pub open_edge_count: u32,
    pub folded_edge_count: u32,
    pub watertight: bool,
    pub from_mesh: bool,
    pub min_angle: f64,
    pub worst_triangle: u32,
    pub longest_edge: f64,
}

/// `CadaclysmBlacksmithFemEdge`: one B-rep edge of a FEM mesh. `id` is the **solid's own**
/// edge id; `face_b` and `end_b` are [`CADACLYSM_BLACKSMITH_NONE`] where there is none, and
/// `0` is a real face and a real vertex.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmBlacksmithFemEdge {
    pub id: u32,
    pub nodes: *const u32,
    pub node_count: u32,
    pub runs: *const u32,
    pub run_count: u32,
    pub face_a: u32,
    pub face_b: u32,
    pub end_a: u32,
    pub end_b: u32,
    pub closed: bool,
    pub seam: bool,
}

/// `CadaclysmBlacksmithFemVertex`: one B-rep vertex of a FEM mesh. `point` is zeroed and
/// meaningless unless `has_position`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmBlacksmithFemVertex {
    pub node: u32,
    pub point: [f64; 3],
    pub has_position: bool,
}

/// A blacksmith document: nodes, parameters, history, branches and an evaluation cache.
/// Opaque, mutable, one thread at a time; freed with `cadaclysm_blacksmith_document_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithDocument {
    _private: [u8; 0],
}

/// `CadaclysmBlacksmithProgress`: `(phase, done, total, user)`, or null for none.
pub type CadaclysmBlacksmithProgress = Option<unsafe extern "C" fn(*const c_char, usize, usize, *mut c_void)>;

/// `CadaclysmBlacksmithDocumentProgress`: `(node, phase, done, total, user)`, or null for none.
pub type CadaclysmBlacksmithDocumentProgress = Option<unsafe extern "C" fn(*const c_char, *const c_char, usize, usize, *mut c_void)>;

type Solid = CadaclysmBlacksmithSolid;
type Assembly = CadaclysmBlacksmithAssembly;
type Profile = CadaclysmBlacksmithProfile;
type Path2 = CadaclysmBlacksmithPath;
type SweepPath = CadaclysmBlacksmithSweepPath;
type Progress = CadaclysmBlacksmithProgress;
type DocumentProgress = CadaclysmBlacksmithDocumentProgress;
type Hits = CadaclysmBlacksmithHits;
type Samples = CadaclysmBlacksmithSamples;
type NurbsCurve = CadaclysmBlacksmithNurbsCurve;
type Intersection = CadaclysmBlacksmithIntersection;
type Check = CadaclysmBlacksmithCheck;
type ProfileList = CadaclysmBlacksmithProfileList;
type Tool = CadaclysmBlacksmithTool;
type Stock = CadaclysmBlacksmithStock;
type Job = CadaclysmBlacksmithJob;
type Programs = CadaclysmBlacksmithPrograms;
type Report = CadaclysmBlacksmithReport;
type Operations = CadaclysmBlacksmithOperations;
type Fem = CadaclysmBlacksmithFemMesh;
type Collider = CadaclysmBlacksmithCollider;
type Classifier = CadaclysmBlacksmithClassifier;
type Projector = CadaclysmBlacksmithProjector;
type TriangleMesh = CadaclysmBlacksmithTriangleMesh;
type Hlr = CadaclysmBlacksmithHlr;
type Page = CadaclysmBlacksmithPage;
type RTree = CadaclysmBlacksmithRTree;
type RTreeHits = CadaclysmBlacksmithRTreeHits;
type RTreePairs = CadaclysmBlacksmithRTreePairs;
type Interpolator = CadaclysmBlacksmithInterpolator;
type Regions = CadaclysmBlacksmithRegions;
type Collisions = CadaclysmBlacksmithCollisions;
type Clashes = CadaclysmBlacksmithClashes;
type SweptClashes = CadaclysmBlacksmithSweptClashes;
type ThicknessGauge = CadaclysmBlacksmithThicknessGauge;
type Thicknesses = CadaclysmBlacksmithThicknesses;
type MeshThicknesses = CadaclysmBlacksmithMeshThicknesses;
type Health = CadaclysmBlacksmithHealth;
type Heal = CadaclysmBlacksmithHeal;
type History = CadaclysmBlacksmithHistory;
type Subd = CadaclysmBlacksmithSubd;
type Sketch = CadaclysmBlacksmithSketch;
type BoxShape = CadaclysmBlacksmithBox;
type Tessellation = CadaclysmBlacksmithTessellation;
type Document = CadaclysmBlacksmithDocument;

entry_points! {
    web; Api, ENTRY_POINTS;
    fn cadaclysm_blacksmith_last_error() -> *const c_char;
    fn cadaclysm_blacksmith_version() -> *const c_char;
    fn cadaclysm_blacksmith_build_date() -> *const c_char;
    fn cadaclysm_blacksmith_license_set(text_or_path: *const c_char) -> bool;
    fn cadaclysm_blacksmith_license_info() -> *const c_char;
    fn cadaclysm_blacksmith_license_notice_count() -> u64;
    fn cadaclysm_blacksmith_brep_layout_id() -> *const c_char;
    fn cadaclysm_blacksmith_from_brep(brep: *const c_void, layout_id: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_free(solid: *mut Solid);
    fn cadaclysm_blacksmith_profile_free(profile: *mut Profile);
    fn cadaclysm_blacksmith_string_free(s: *mut c_char);

    fn cadaclysm_blacksmith_profile_rect(w: f64, h: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_circle(r: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_slot(cx: f64, cy: f64, length: f64, r: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_polygon(xy: *const f64, count: usize) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_regular_polygon(cx: f64, cy: f64, radius: f64, sides: u32, angle: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_circumscribed_polygon(cx: f64, cy: f64, radius: f64, sides: u32, angle: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_star(cx: f64, cy: f64, outer: f64, inner: f64, points: u32, angle: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_spline(
        xy: *const f64,
        count: usize,
        degree: u32,
        weights: *const f64,
        closed: bool
    ) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_round(
        profile: *const Profile,
        radius: f64,
        corners: *const u32,
        count: usize,
        open: bool
    ) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_chain(pieces: *const *const Profile, count: usize, tolerance: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_polyline(xy: *const f64, count: usize, closed: bool) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_arc(cx: f64, cy: f64, r: f64, a0: f64, a1: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_arc_through(x0: f64, y0: f64, xm: f64, ym: f64, x1: f64, y1: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_from_beziers(beziers: *const f64, count: usize, recognise: bool) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_bezier_count(profile: *const Profile) -> u32;
    fn cadaclysm_blacksmith_profile_beziers(profile: *const Profile, frame: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_profile_loops(pieces: *const *const Profile, count: usize, tolerance: f64, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_profile_chain_order(pieces: *const *const Profile, count: usize, tolerance: f64, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_profile_from_loops(loops: *const *const Profile, count: usize) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_close_loop(profile: *const Profile) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_piece_count(profile: *const Profile, cutters: *const *const Profile, count: usize, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_profile_piece(profile: *const Profile, cutters: *const *const Profile, count: usize, index: u32, tolerance: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_trim_count(profile: *const Profile, cutters: *const *const Profile, count: usize, piece: u32, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_profile_trim_chain(profile: *const Profile, cutters: *const *const Profile, count: usize, piece: u32, index: u32, tolerance: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_polylines(profile: *const Profile, tolerance: f64) -> CadaclysmBlacksmithPolylines;
    fn cadaclysm_blacksmith_profile_coloured(profile: *const Profile, r: f64, g: f64, b: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_colour(profile: *const Profile, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_profile_with_hole(outer: *const Profile, hole: *const Profile) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_hits(a: *const Profile, b: *const Profile, tolerance: f64) -> *mut Hits;
    fn cadaclysm_blacksmith_hits_free(hits: *mut Hits);
    fn cadaclysm_blacksmith_hit_count(hits: *const Hits) -> u32;
    fn cadaclysm_blacksmith_hit(hits: *const Hits, i: u32, out: *mut CadaclysmBlacksmithHit) -> bool;
    fn cadaclysm_blacksmith_solid_profile_hits(solid: *const Solid, profile: *const Profile, frame: *const f64, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Hits;
    fn cadaclysm_blacksmith_hits_piece_count(hits: *const Hits) -> u32;
    fn cadaclysm_blacksmith_hits_piece(hits: *const Hits, i: u32, inside: *mut bool, start: *mut CadaclysmBlacksmithSpot, end: *mut CadaclysmBlacksmithSpot) -> bool;
    fn cadaclysm_blacksmith_hits_piece_profile(hits: *const Hits, i: u32) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_common(a: *const Profile, b: *const Profile, tolerance: f64) -> *mut ProfileList;
    fn cadaclysm_blacksmith_profile_text(
        text: *const c_char,
        size: f64,
        font: *const c_char,
        font_bytes: *const u8,
        font_len: usize,
        halign: *const c_char,
        valign: *const c_char,
        spacing: f64,
        direction: *const c_char
    ) -> *mut ProfileList;
    fn cadaclysm_blacksmith_profile_list_count(list: *const ProfileList) -> u32;
    fn cadaclysm_blacksmith_profile_list_get(list: *const ProfileList, i: u32) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_list_free(list: *mut ProfileList);
    fn cadaclysm_blacksmith_translate_profile(profile: *const Profile, dx: f64, dy: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_rotate(profile: *const Profile, cx: f64, cy: f64, radians: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_scale(profile: *const Profile, cx: f64, cy: f64, sx: f64, sy: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_mirror(profile: *const Profile, px: f64, py: f64, dx: f64, dy: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_transform2d(profile: *const Profile, m: *const f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_to_arcs(profile: *const Profile, tolerance: f64) -> *mut Profile;
    fn cadaclysm_blacksmith_profile_offset(profile: *const Profile, distance: f64, tolerance: f64) -> *mut ProfileList;

    fn cadaclysm_blacksmith_path_begin(x: f64, y: f64) -> *mut Path2;
    fn cadaclysm_blacksmith_path_line_to(p: *mut Path2, x: f64, y: f64) -> bool;
    fn cadaclysm_blacksmith_path_arc_to(p: *mut Path2, x: f64, y: f64, cx: f64, cy: f64, ccw: bool) -> bool;
    fn cadaclysm_blacksmith_path_bezier_to(p: *mut Path2, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) -> bool;
    fn cadaclysm_blacksmith_path_conic_to(p: *mut Path2, x: f64, y: f64, cx: f64, cy: f64, weight: f64) -> bool;
    fn cadaclysm_blacksmith_path_parabola_by_vertex(p: *mut Path2, x: f64, y: f64, vx: f64, vy: f64) -> bool;
    fn cadaclysm_blacksmith_path_parabola_by_focus(p: *mut Path2, x: f64, y: f64, fx: f64, fy: f64) -> bool;
    fn cadaclysm_blacksmith_path_parabola(vx: f64, vy: f64, ax: f64, ay: f64, focal: f64, from: f64, to: f64) -> *mut Path2;
    fn cadaclysm_blacksmith_path_nurbs_to(
        p: *mut Path2,
        control_xy: *const f64,
        control_count: usize,
        weights: *const f64,
        knots: *const f64,
        knot_count: usize,
        degree: u32
    ) -> bool;
    fn cadaclysm_blacksmith_path_end(p: *mut Path2) -> *mut Profile;
    fn cadaclysm_blacksmith_path_end_open(p: *mut Path2) -> *mut Profile;
    fn cadaclysm_blacksmith_path_free(p: *mut Path2);

    fn cadaclysm_blacksmith_sweep_path_begin(x: f64, y: f64, z: f64) -> *mut SweepPath;
    fn cadaclysm_blacksmith_sweep_path_line_to(p: *mut SweepPath, x: f64, y: f64, z: f64) -> bool;
    fn cadaclysm_blacksmith_sweep_path_arc(
        p: *mut SweepPath,
        cx: f64,
        cy: f64,
        cz: f64,
        ax: f64,
        ay: f64,
        az: f64,
        angle: f64
    ) -> bool;
    fn cadaclysm_blacksmith_sweep_path_along(curve: *const Profile, frame: *const f64, tolerance: f64, open: bool) -> *mut SweepPath;
    fn cadaclysm_blacksmith_sweep_path_free(p: *mut SweepPath);

    fn cadaclysm_blacksmith_cuboid(x: f64, y: f64, z: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_cylinder(r: f64, h: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_cone(r: f64, h: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_sphere(r: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_torus(major: f64, minor: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_wedge(x: f64, y: f64, z: f64, top_x: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_pyramid(sides: u32, r: f64, h: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude(profile: *const Profile, frame: *const f64, height: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_open(profile: *const Profile, frame: *const f64, height: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_tapered(profile: *const Profile, frame: *const f64, height: f64, taper: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_open_tapered(profile: *const Profile, frame: *const f64, height: f64, taper: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_between(profile: *const Profile, frame: *const f64, bottom: *const f64, top: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_open_between(profile: *const Profile, frame: *const f64, bottom: *const f64, top: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_slant_of_plane(frame: *const f64, point: *const f64, normal: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_frame_midplane(a: *const f64, b: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_frame_through(p: *const f64, q: *const f64, r: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_loft(a: *const Profile, frame_a: *const f64, b: *const Profile, frame_b: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_loft_open(a: *const Profile, frame_a: *const f64, b: *const Profile, frame_b: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_loft_through(profiles: *const *const Profile, frames: *const f64, count: usize) -> *mut Solid;
    fn cadaclysm_blacksmith_loft_through_open(profiles: *const *const Profile, frames: *const f64, count: usize) -> *mut Solid;
    fn cadaclysm_blacksmith_revolve(profile: *const Profile, axis: *const f64, angle: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_revolve_open(profile: *const Profile, axis: *const f64, angle: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_coil(profile: *const Profile, axis: *const f64, pitch: f64, turns: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_revolve_in_plane(profile: *const Profile, frame: *const f64, axis: *const f64, angle: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_revolve_open_in_plane(profile: *const Profile, frame: *const f64, axis: *const f64, angle: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_sweep(profile: *const Profile, frame: *const f64, path: *const SweepPath) -> *mut Solid;
    fn cadaclysm_blacksmith_sweep_open(profile: *const Profile, frame: *const f64, path: *const SweepPath) -> *mut Solid;
    fn cadaclysm_blacksmith_pipe(path: *const SweepPath, radius: f64, thickness: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_face(profile: *const Profile, frame: *const f64) -> *mut Solid;

    fn cadaclysm_blacksmith_extrude_faces(sheet: *const Solid, height: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_face_sheet(solid: *const Solid, face: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_drop_faces(solid: *const Solid, faces: *const u32, count: usize) -> *mut Solid;
    fn cadaclysm_blacksmith_place(solid: *const Solid, frame: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_translate(solid: *const Solid, dx: f64, dy: f64, dz: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_scaled(solid: *const Solid, factor: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_rotate(solid: *const Solid, axis: *const f64, radians: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_mirror(solid: *const Solid, plane: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_transform(solid: *const Solid, matrix: *const f64, inexact_out: *mut u32) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_convert_to_nurbs(solid: *const Solid, level: u32, inexact_out: *mut u32) -> *mut Solid;

    fn cadaclysm_blacksmith_transform_translation(v: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_rotation(axis: *const f64, radians: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_mirror(plane: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_scale(centre: *const f64, k: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_scale_xyz(frame: *const f64, sx: f64, sy: f64, sz: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_shear(plane: *const f64, dir: *const f64, factor: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_plane_to_plane(a: *const f64, b: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_change_basis(from: *const f64, to: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_planar_projection(plane: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_project_along(plane: *const f64, dir: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_compose(a: *const f64, b: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_inverse(m: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_is_rigid(m: *const f64, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_transform_is_similarity(m: *const f64, tolerance: f64) -> f64;
    fn cadaclysm_blacksmith_transform_decompose_rigid(m: *const f64, tolerance: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_decompose_similarity(m: *const f64, tolerance: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_transform_decompose_affine(m: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_quaternion_from_axis_angle(dir: *const f64, radians: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_quaternion_from_transform(m: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_quaternion_to_transform(q: *const f64, centre: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_quaternion_slerp(a: *const f64, b: *const f64, s: f64, out: *mut f64) -> bool;

    // Value geometry: every value a flat array of doubles tagged with a kind
    // (`CADACLYSM_BLACKSMITH_VALUE_*`).
    fn cadaclysm_blacksmith_value_size(kind: u32) -> u32;
    fn cadaclysm_blacksmith_value_check(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_value_bounds(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_value_transform(kind: u32, value: *const f64, matrix: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_curve_value_point_at(kind: u32, value: *const f64, t: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_curve_value_tangent_at(kind: u32, value: *const f64, t: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_curve_value_length(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_curve_value_closest_point(kind: u32, value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_curve_value_to_nurbs(kind: u32, value: *const f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_circle_through(a: *const f64, b: *const f64, c: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_arc_through(a: *const f64, b: *const f64, c: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_arc_from_start_tangent_end(a: *const f64, tangent: *const f64, c: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_ellipse_from_circle(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_surface_value_point_at(kind: u32, value: *const f64, u: f64, v: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_surface_value_normal_at(kind: u32, value: *const f64, u: f64, v: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_surface_value_closest_point(kind: u32, value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_surface_value_domain(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_surface_value_nurbs_sheet(kind: u32, value: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_value_contains(kind: u32, value: *const f64, point: *const f64, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_solid_value_area(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_solid_value_volume(kind: u32, value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_solid_value_to_solid(kind: u32, value: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_cuboid_from_bounds(min: *const f64, max: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_cuboid_around(frame: *const f64, xyz: *const f64, count: usize, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_cuboid_corners(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_cuboid_point_at(value: *const f64, sx: f64, sy: f64, sz: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_cuboid_closest_point(value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_frame_fit(xyz: *const f64, count: usize, out: *mut f64, deviation_out: *mut f64) -> bool;
    // The rectangle, the triangle and the ray (value kinds 9-11, plan B4).
    fn cadaclysm_blacksmith_rectangle_corners(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_rectangle_area(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_rectangle_closest_point(value: *const f64, point: *const f64, include_interior: bool, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_rectangle_contains(value: *const f64, point: *const f64, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_rectangle_to_sheet(value: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_triangle_area(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_perimeter(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_centroid(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_circumcircle(value: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_point_at(value: *const f64, wa: f64, wb: f64, wc: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_barycentric(value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_closest_point(value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_edge(value: *const f64, index: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_to_sheet(value: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_ray_point_at(value: *const f64, t: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_ray_closest_point(value: *const f64, point: *const f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_coloured(solid: *const Solid, face: u32, r: f64, g: f64, b: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_edges_coloured(solid: *const Solid, edges: *const u32, count: usize, r: f64, g: f64, b: f64) -> *mut Solid;

    fn cadaclysm_blacksmith_solid_section(solid: *const Solid, z: f64, tolerance: f64) -> *mut ProfileList;
    fn cadaclysm_blacksmith_join(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_merge(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_regions(solid: *const Solid) -> *mut Regions;
    fn cadaclysm_blacksmith_regions_count(regions: *const Regions) -> u32;
    fn cadaclysm_blacksmith_regions_at(regions: *const Regions, i: u32, out: *mut CadaclysmBlacksmithRegion) -> bool;
    fn cadaclysm_blacksmith_regions_side_at(regions: *const Regions, i: u32, k: u32, out: *mut CadaclysmBlacksmithFaceSide) -> bool;
    fn cadaclysm_blacksmith_regions_free(regions: *mut Regions);
    fn cadaclysm_blacksmith_region_solid(solid: *const Solid, region: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_cut(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_common(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_split_sheet(
        sheet: *const Solid,
        tool: *const Solid,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_trim(
        sheet: *const Solid,
        tool: *const Solid,
        keep_inside: bool,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_fillet(
        solid: *const Solid,
        edges: *const u32,
        count: usize,
        radius: f64,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_chamfer(solid: *const Solid, edges: *const u32, count: usize, distance: f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_push_pull(
        solid: *const Solid,
        face: u32,
        distance: f64,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_push_pull_faces(
        solid: *const Solid,
        faces: *const u32,
        count: usize,
        distance: f64,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_split(solid: *const Solid, tool: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_split_by_plane(
        solid: *const Solid,
        plane: *const f64,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_split_by_profile(
        solid: *const Solid,
        profile: *const Profile,
        frame: *const f64,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_shell(
        solid: *const Solid,
        thickness: f64,
        open_faces: *const u32,
        count: usize,
        tolerance: f64,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_thicken(solid: *const Solid, thickness: f64, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
    fn cadaclysm_blacksmith_merge_flush(solid: *const Solid) -> *mut Solid;
    fn cadaclysm_blacksmith_refillet(solid: *const Solid, face: u32, radius: f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_unfillet(solid: *const Solid, face: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_rechamfer(solid: *const Solid, face: u32, distance: f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_unchamfer(solid: *const Solid, face: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_lump_count(solid: *const Solid) -> u32;
    fn cadaclysm_blacksmith_lump(solid: *const Solid, index: u32) -> *mut Solid;

    fn cadaclysm_blacksmith_face_count(solid: *const Solid) -> u32;
    fn cadaclysm_blacksmith_select_face(solid: *const Solid, kind: u32, v: *const f64, index: u32) -> u32;
    fn cadaclysm_blacksmith_face_frame(solid: *const Solid, face: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_face_ref(solid: *const Solid, face: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_find_face(solid: *const Solid, face_ref: *const f64, hint: i32, tolerance: f64) -> i32;
    fn cadaclysm_blacksmith_edge_ref(solid: *const Solid, edge: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_find_edge(solid: *const Solid, edge_ref: *const f64, tolerance: f64) -> i32;
    fn cadaclysm_blacksmith_vertex_count(solid: *const Solid) -> u32;
    fn cadaclysm_blacksmith_vertex_ref(solid: *const Solid, vertex: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_find_vertex(solid: *const Solid, vertex_ref: *const f64, tolerance: f64) -> i32;
    fn cadaclysm_blacksmith_solid_tracked(solid: *const Solid) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_is_tracked(solid: *const Solid) -> bool;
    fn cadaclysm_blacksmith_face_id(solid: *const Solid, face: u32) -> u64;
    fn cadaclysm_blacksmith_face_with_id(solid: *const Solid, id: u64) -> u32;
    fn cadaclysm_blacksmith_face_origin_count(solid: *const Solid, face: u32) -> u32;
    fn cadaclysm_blacksmith_face_origin_at(solid: *const Solid, face: u32, i: u32, operand: *mut u32, id: *mut u64) -> bool;
    fn cadaclysm_blacksmith_edge_id(solid: *const Solid, edge: u32) -> u64;
    fn cadaclysm_blacksmith_edge_with_id(solid: *const Solid, id: u64) -> u32;
    fn cadaclysm_blacksmith_edge_origin_count(solid: *const Solid, edge: u32) -> u32;
    fn cadaclysm_blacksmith_edge_origin_at(solid: *const Solid, edge: u32, i: u32, operand: *mut u32, id: *mut u64) -> bool;
    fn cadaclysm_blacksmith_origins_through(out: *const Solid, via: *const Solid) -> *mut Solid;
    fn cadaclysm_blacksmith_with_attribute(solid: *const Solid, key: *const c_char, value: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_without_attribute(solid: *const Solid, key: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_attribute(solid: *const Solid, key: *const c_char) -> *const c_char;
    fn cadaclysm_blacksmith_attribute_count(solid: *const Solid) -> u32;
    fn cadaclysm_blacksmith_attribute_key_at(solid: *const Solid, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_attribute_value_at(solid: *const Solid, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_with_face_attribute(solid: *const Solid, face: u32, key: *const c_char, value: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_without_face_attribute(solid: *const Solid, face: u32, key: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_face_attribute(solid: *const Solid, face: u32, key: *const c_char) -> *const c_char;
    fn cadaclysm_blacksmith_face_attribute_count(solid: *const Solid, face: u32) -> u32;
    fn cadaclysm_blacksmith_face_attribute_key_at(solid: *const Solid, face: u32, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_face_attribute_value_at(solid: *const Solid, face: u32, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_history(out: *const Solid, inputs: *const *const Solid, count: usize) -> *mut History;
    fn cadaclysm_blacksmith_edge_history(out: *const Solid, inputs: *const *const Solid, count: usize) -> *mut History;
    fn cadaclysm_blacksmith_history_free(history: *mut History);
    fn cadaclysm_blacksmith_history_kept_count(history: *const History) -> u32;
    fn cadaclysm_blacksmith_history_kept_at(history: *const History, i: u32, operand: *mut u32, id: *mut u64, out_id: *mut u64) -> bool;
    fn cadaclysm_blacksmith_history_modified_count(history: *const History) -> u32;
    fn cadaclysm_blacksmith_history_modified_at(history: *const History, i: u32, operand: *mut u32, id: *mut u64) -> bool;
    fn cadaclysm_blacksmith_history_modified_output_count(history: *const History, i: u32) -> u32;
    fn cadaclysm_blacksmith_history_modified_output_at(history: *const History, i: u32, j: u32) -> u64;
    fn cadaclysm_blacksmith_history_generated_count(history: *const History) -> u32;
    fn cadaclysm_blacksmith_history_generated_at(history: *const History, i: u32) -> u64;
    fn cadaclysm_blacksmith_history_deleted_count(history: *const History) -> u32;
    fn cadaclysm_blacksmith_history_deleted_at(history: *const History, i: u32, operand: *mut u32, id: *mut u64) -> bool;
    fn cadaclysm_blacksmith_colour(solid: *const Solid, face: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_edge_colour(solid: *const Solid, edge: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_parse_colour(text: *const c_char, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_option_set(name: *const c_char, value: f64) -> bool;
    fn cadaclysm_blacksmith_option_get(name: *const c_char, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_face_kind(solid: *const Solid, face: u32) -> *const c_char;
    fn cadaclysm_blacksmith_edge_count(solid: *const Solid) -> u32;
    fn cadaclysm_blacksmith_edge(solid: *const Solid, i: u32, out: *mut CadaclysmBlacksmithEdge) -> bool;
    fn cadaclysm_blacksmith_edge_curve(solid: *const Solid, i: u32, out: *mut CadaclysmBlacksmithCurve) -> bool;
    fn cadaclysm_blacksmith_intersect(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Intersection;
    fn cadaclysm_blacksmith_self_intersect(solid: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Intersection;
    fn cadaclysm_blacksmith_intersection_free(intersection: *mut Intersection);
    fn cadaclysm_blacksmith_intersection_chain_count(intersection: *const Intersection) -> u32;
    fn cadaclysm_blacksmith_intersection_chain(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithChain) -> bool;
    fn cadaclysm_blacksmith_intersection_curve(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithCurve) -> bool;
    fn cadaclysm_blacksmith_intersection_overlap_count(intersection: *const Intersection) -> u32;
    fn cadaclysm_blacksmith_intersection_overlap(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithOverlap) -> bool;
    fn cadaclysm_blacksmith_check(a: *const Solid, b: *const Solid, operation: *const c_char, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Check;
    fn cadaclysm_blacksmith_check_free(check: *mut Check);
    fn cadaclysm_blacksmith_check_count(check: *const Check) -> u32;
    fn cadaclysm_blacksmith_check_finding(check: *const Check, i: u32, out: *mut CadaclysmBlacksmithFinding) -> bool;
    fn cadaclysm_blacksmith_leaked_edges(solid: *const Solid, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_unpaired_edges(solid: *const Solid, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_manifold(solid: *const Solid, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_face_round_radius(solid: *const Solid, face: u32) -> f64;
    fn cadaclysm_blacksmith_face_chamfer_distance(solid: *const Solid, face: u32) -> f64;
    fn cadaclysm_blacksmith_edge_bezier_count(solid: *const Solid, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_edge_beziers(solid: *const Solid, tolerance: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_isocurve_bezier_count(solid: *const Solid, density: u32, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_isocurve_beziers(solid: *const Solid, density: u32, tolerance: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_health(solid: *const Solid, tolerance: f64, mesh: bool) -> *mut Health;
    fn cadaclysm_blacksmith_health_free(health: *mut Health);
    fn cadaclysm_blacksmith_health_summary(health: *const Health, counts: *mut u32, sizes: *mut f64) -> bool;
    fn cadaclysm_blacksmith_health_free_edges(health: *const Health, ids: *mut u32, sizes: *mut f64) -> u32;
    fn cadaclysm_blacksmith_health_wires(health: *const Health, runs: *mut u32, sizes: *mut f64) -> u32;
    fn cadaclysm_blacksmith_health_small(health: *const Health, items: *mut u32, sizes: *mut f64) -> u32;
    fn cadaclysm_blacksmith_health_crack_edges(health: *const Health, ids: *mut u32) -> u32;
    fn cadaclysm_blacksmith_healed(solid: *const Solid, tolerance: f64, flags: u32) -> *mut Heal;
    fn cadaclysm_blacksmith_heal_body(h: *const Heal) -> *mut Solid;
    fn cadaclysm_blacksmith_heal_free(h: *mut Heal);
    fn cadaclysm_blacksmith_heal_summary(h: *const Heal, counts: *mut u32, sizes: *mut f64) -> bool;
    fn cadaclysm_blacksmith_heal_fixes(h: *const Heal, items: *mut u32, sizes: *mut f64) -> u32;
    fn cadaclysm_blacksmith_heal_refused(h: *const Heal, items: *mut u32, sizes: *mut f64) -> u32;
    fn cadaclysm_blacksmith_edge_tolerance(solid: *const Solid, edge: u32) -> f64;
    fn cadaclysm_blacksmith_effective_tolerance(solids: *const *const Solid, count: usize) -> f64;
    fn cadaclysm_blacksmith_solid_tolerances(solid: *const Solid, absolute: *mut f64, angular: *mut f64) -> bool;
    fn cadaclysm_blacksmith_solid_with_tolerances(solid: *const Solid, absolute: f64, angular: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_vertex_tolerance(solid: *const Solid, x: f64, y: f64, z: f64) -> f64;
    fn cadaclysm_blacksmith_mass_properties(solid: *const Solid, accuracy: f64,
                                           out: *mut CadaclysmBlacksmithMassProperties) -> bool;
    fn cadaclysm_blacksmith_oriented_box(solid: *const Solid, accuracy: f64, out: *mut CadaclysmBlacksmithOrientedBox) -> bool;
    fn cadaclysm_blacksmith_edge_length(solid: *const Solid, edge: u32, accuracy: f64, out: *mut CadaclysmBlacksmithLength) -> bool;
    fn cadaclysm_blacksmith_profile_length(profile: *const Profile, accuracy: f64, out: *mut CadaclysmBlacksmithLength) -> bool;
    fn cadaclysm_blacksmith_edge_point_at_length(solid: *const Solid, edge: u32, s: f64, accuracy: f64, out: *mut CadaclysmBlacksmithAt) -> bool;
    fn cadaclysm_blacksmith_edge_divide_by_count(solid: *const Solid, edge: u32, n: u32, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_edge_divide_by_length(solid: *const Solid, edge: u32, step: f64, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_profile_point_at_length(profile: *const Profile, s: f64, accuracy: f64, out: *mut CadaclysmBlacksmithAt) -> bool;
    fn cadaclysm_blacksmith_profile_divide_by_count(profile: *const Profile, n: u32, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_profile_divide_by_length(profile: *const Profile, step: f64, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_samples_count(samples: *const Samples) -> u32;
    fn cadaclysm_blacksmith_samples_at(samples: *const Samples, i: u32, out: *mut CadaclysmBlacksmithAt) -> bool;
    fn cadaclysm_blacksmith_samples_free(samples: *mut Samples);

    // NurbsCurve: curves in space.
    fn cadaclysm_blacksmith_nurbs_curve_new(xyz: *const f64, count: usize, weights: *const f64, degree: u32, knots: *const f64, knot_count: usize) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_through(xyz: *const f64, count: usize, degree: u32, closed: bool, start: *const f64, end: *const f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_fit(xyz: *const f64, count: usize, degree: u32, tolerance: f64, error_out: *mut f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_fair(
        xyz: *const f64,
        count: usize,
        degree: u32,
        tolerance: f64,
        no_inflection: bool,
        span_from: f64,
        span_to: f64,
        error_out: *mut f64
    ) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_faired(
        curve: *const NurbsCurve,
        degree: u32,
        tolerance: f64,
        no_inflection: bool,
        span_from: f64,
        span_to: f64,
        error_out: *mut f64
    ) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_from_edge(solid: *const Solid, edge: u32) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(solid: *const Solid, face: u32, along_u: bool, at: f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_blend(a: *const NurbsCurve, a_end: bool, b: *const NurbsCurve, b_end: bool, continuity: u32, bulge: f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_projected_to_plane(curve: *const NurbsCurve, origin: *const f64, normal: *const f64, direction: *const f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_projected_to_face(curve: *const NurbsCurve, solid: *const Solid, face: u32, direction: *const f64, tolerance: f64, error_out: *mut f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(curve: *const NurbsCurve, solid: *const Solid, distance: f64, tolerance: f64, error_out: *mut f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_pulled_to_face(curve: *const NurbsCurve, solid: *const Solid, face: u32, tolerance: f64, error_out: *mut f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_reversed(curve: *const NurbsCurve) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_trimmed(curve: *const NurbsCurve, t0: f64, t1: f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_extended(curve: *const NurbsCurve, at_start: bool, length: f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_elevated(curve: *const NurbsCurve, by: u32) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_joined(curves: *const *const NurbsCurve, count: usize, tolerance: f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_tween(a: *const NurbsCurve, b: *const NurbsCurve, count: u32, method: u32, samples: u32, align: bool, tolerance: f64, out: *mut *mut NurbsCurve) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_transformed(curve: *const NurbsCurve, matrix: *const f64) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_clone(curve: *const NurbsCurve) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_nurbs_curve_free(curve: *mut NurbsCurve);
    fn cadaclysm_blacksmith_nurbs_curve_degree(curve: *const NurbsCurve) -> u32;
    fn cadaclysm_blacksmith_nurbs_curve_control_count(curve: *const NurbsCurve) -> u32;
    fn cadaclysm_blacksmith_nurbs_curve_knot_count(curve: *const NurbsCurve) -> u32;
    fn cadaclysm_blacksmith_nurbs_curve_control_points(curve: *const NurbsCurve, xyz: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_weights(curve: *const NurbsCurve, w: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_knots(curve: *const NurbsCurve, k: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_is_rational(curve: *const NurbsCurve) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_is_closed(curve: *const NurbsCurve) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_domain(curve: *const NurbsCurve, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_point(curve: *const NurbsCurve, t: f64, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_derivatives(curve: *const NurbsCurve, t: f64, order: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_curvature(curve: *const NurbsCurve, t: f64, out: *mut CadaclysmBlacksmithCurvature) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_length(curve: *const NurbsCurve, accuracy: f64, out: *mut CadaclysmBlacksmithLength) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_point_at_length(curve: *const NurbsCurve, s: f64, accuracy: f64, out: *mut CadaclysmBlacksmithAt) -> bool;
    fn cadaclysm_blacksmith_nurbs_curve_divide_by_count(curve: *const NurbsCurve, n: u32, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_nurbs_curve_divide_by_length(curve: *const NurbsCurve, step: f64, accuracy: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_nurbs_curve_plane_hits(curve: *const NurbsCurve, origin: *const f64, normal: *const f64) -> *mut Samples;
    fn cadaclysm_blacksmith_nurbs_curve_face_hits(curve: *const NurbsCurve, solid: *const Solid, face: u32, tolerance: f64) -> *mut Samples;
    fn cadaclysm_blacksmith_nurbs_curve_inflections(curve: *const NurbsCurve) -> *mut Samples;
    fn cadaclysm_blacksmith_nurbs_curve_knot_continuity(curve: *const NurbsCurve, out: *mut CadaclysmBlacksmithKnotContinuity) -> bool;
    fn cadaclysm_blacksmith_loft_curves(sections: *const *const NurbsCurve, count: usize, degree: u32, loose: bool, closed: bool) -> *mut Solid;
    fn cadaclysm_blacksmith_sweep_rail(
        rail: *const NurbsCurve,
        sections: *const *const NurbsCurve,
        count: usize,
        frame: u32,
        up: *const f64,
        tolerance: f64,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_sweep_two_rails(
        rail_a: *const NurbsCurve,
        rail_b: *const NurbsCurve,
        sections: *const *const NurbsCurve,
        count: usize,
        tolerance: f64,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_edge_surface(curves: *const *const NurbsCurve, count: usize, tolerance: f64, error_out: *mut f64) -> *mut Solid;
    fn cadaclysm_blacksmith_network_surface(
        u_curves: *const *const NurbsCurve,
        u_count: usize,
        v_curves: *const *const NurbsCurve,
        v_count: usize,
        tolerance: f64,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_continuity(
        a: *const Solid,
        face_a: u32,
        side_a: u32,
        b: *const Solid,
        face_b: u32,
        side_b: u32,
        samples: u32,
        out: *mut CadaclysmBlacksmithContinuity
    ) -> bool;
    fn cadaclysm_blacksmith_edge_continuity(solid: *const Solid, edge: u32, samples: u32, out: *mut CadaclysmBlacksmithContinuity) -> bool;
    fn cadaclysm_blacksmith_surface_faired(
        solid: *const Solid,
        face: u32,
        tolerance: f64,
        degree: u32,
        controls_u: u32,
        controls_v: u32,
        keep: *const i32,
        no_inflection: u32,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_curvature_turns(solid: *const Solid, face: u32, samples: u32, out: *mut CadaclysmBlacksmithCurvatureTurns) -> bool;
    fn cadaclysm_blacksmith_curvature_turn_points(solid: *const Solid, face: u32, samples: u32, mean: bool) -> *mut Samples;
    fn cadaclysm_blacksmith_highlight_kink(solid: *const Solid, edge: u32, samples: u32, out: *mut CadaclysmBlacksmithHighlightKink) -> bool;
    fn cadaclysm_blacksmith_match_side(a: *const Solid, face_a: u32, side_a: u32, b: *const Solid, face_b: u32, side_b: u32, level: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_blend_sides(
        a: *const Solid,
        face_a: u32,
        side_a: u32,
        b: *const Solid,
        face_b: u32,
        side_b: u32,
        level: u32,
        bulge: f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_n_sided_patch(
        boundaries: *const CadaclysmBlacksmithPatchBoundary,
        count: usize,
        bulge: f64,
        tolerance: f64,
        report_out: *mut CadaclysmBlacksmithPatchReport
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_fillet_surfaces(
        a: *const Solid,
        face_a: u32,
        b: *const Solid,
        face_b: u32,
        radius_start: f64,
        radius_end: f64,
        flip_a: bool,
        flip_b: bool,
        tolerance: f64,
        rail_a: *mut *mut NurbsCurve,
        rail_b: *mut *mut NurbsCurve,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_fillet_varying(solid: *const Solid, edges: *const u32, count: usize, radius_start: f64, radius_end: f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_fillet_law(solid: *const Solid, edges: *const u32, count: usize, shares: *const f64, radii: *const f64, station_count: usize, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_split_by_curve(sheet: *const Solid, curve: *const NurbsCurve, direction: *const f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_trim_by_curve(sheet: *const Solid, curve: *const NurbsCurve, direction: *const f64, keep_inside: bool, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_join_sheets(sheets: *const *const Solid, count: usize, tolerance: f64, report: *mut CadaclysmBlacksmithJoinReport) -> *mut Solid;
    fn cadaclysm_blacksmith_split_along_curve(sheet: *const Solid, curve: *const NurbsCurve, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_panel_gap(sheet: *const Solid, curve: *const NurbsCurve, gap: f64, flange: f64, tolerance: f64, out: *mut *mut Solid) -> bool;
    fn cadaclysm_blacksmith_flange(
        sheet: *const Solid,
        edges: *const u32,
        count: usize,
        section: *const NurbsCurve,
        tolerance: f64,
        join: bool,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_extrude_to(
        sheet: *const Solid,
        edges: *const u32,
        count: usize,
        direction: *const f64,
        target: *const Solid,
        tolerance: f64,
        join: bool,
        error_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_recess(sheet: *const Solid, outline: *const NurbsCurve, depth: f64, draft: f64, fillet: f64, pane: bool, tolerance: f64, faces_out: *mut u32) -> *mut Solid;
    fn cadaclysm_blacksmith_mirror_join(half: *const Solid, plane: *const f64, snap: f64, tolerance: f64, report_out: *mut f64) -> *mut Solid;
    fn cadaclysm_blacksmith_pattern_rectangular(
        direction1: *const f64,
        count1: u32,
        spacing1: f64,
        direction2: *const f64,
        count2: u32,
        spacing2: f64,
        symmetric: bool,
        skip: *const u32,
        skip_count: u32,
        out: *mut f64
    ) -> u32;
    fn cadaclysm_blacksmith_pattern_circular(axis: *const f64, count: u32, angle: f64, symmetric: bool, skip: *const u32, skip_count: u32, out: *mut f64) -> u32;
    fn cadaclysm_blacksmith_pattern_along(curve: *const NurbsCurve, count: u32, spacing: f64, orient: u32, skip: *const u32, skip_count: u32, out: *mut f64) -> u32;
    fn cadaclysm_blacksmith_pattern(solid: *const Solid, transforms: *const f64, count: u32, tolerance: f64, report_out: *mut f64) -> *mut Solid;
    fn cadaclysm_blacksmith_pattern_feature(solid: *const Solid, tool: *const Solid, op: u32, transforms: *const f64, count: u32, tolerance: f64, report_out: *mut f64) -> *mut Solid;
    fn cadaclysm_blacksmith_hole(
        solid: *const Solid,
        points: *const f64,
        count: u32,
        diameter: f64,
        direction: *const f64,
        extent: u32,
        depth: f64,
        tip_angle: f64,
        face: u32,
        head: u32,
        head_diameter: f64,
        head_depth: f64,
        head_angle: f64,
        tolerance: f64,
        report_out: *mut f64,
        bottoms_out: *mut f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_hole_tool(
        solid: *const Solid,
        points: *const f64,
        count: u32,
        diameter: f64,
        direction: *const f64,
        extent: u32,
        depth: f64,
        tip_angle: f64,
        face: u32,
        head: u32,
        head_diameter: f64,
        head_depth: f64,
        head_angle: f64,
        tolerance: f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_rib(solid: *const Solid, curve: *const NurbsCurve, plane: *const f64, thickness: f64, side: u32, toward: *const f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_rib_tool(solid: *const Solid, curve: *const NurbsCurve, plane: *const f64, thickness: f64, side: u32, toward: *const f64, tolerance: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_web(
        solid: *const Solid,
        curves: *const *const NurbsCurve,
        count: u32,
        plane: *const f64,
        thickness: f64,
        side: u32,
        depth: f64,
        both_ways: bool,
        tolerance: f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_web_tool(
        solid: *const Solid,
        curves: *const *const NurbsCurve,
        count: u32,
        plane: *const f64,
        thickness: f64,
        side: u32,
        depth: f64,
        both_ways: bool,
        tolerance: f64
    ) -> *mut Solid;
    fn cadaclysm_blacksmith_classifier_new(solid: *const Solid, tolerance: f64) -> *mut Classifier;
    fn cadaclysm_blacksmith_classifier_contains(classifier: *const Classifier, point: *const f64, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_classifier_free(classifier: *mut Classifier);
    fn cadaclysm_blacksmith_rtree_new() -> *mut RTree;
    fn cadaclysm_blacksmith_rtree_from_boxes(ids: *const u32, boxes: *const f64, n: u32) -> *mut RTree;
    fn cadaclysm_blacksmith_rtree_from_points(xyz: *const f64, n: u32) -> *mut RTree;
    fn cadaclysm_blacksmith_rtree_from_triangles(xyz: *const f64, n_points: u32, indices: *const u32, n_triangles: u32) -> *mut RTree;
    fn cadaclysm_blacksmith_solid_face_tree(solid: *const Solid) -> *mut RTree;
    fn cadaclysm_blacksmith_rtree_insert(tree: *mut RTree, id: u32, box_: *const f64) -> bool;
    fn cadaclysm_blacksmith_rtree_insert_point(tree: *mut RTree, id: u32, p: *const f64) -> bool;
    fn cadaclysm_blacksmith_rtree_remove(tree: *mut RTree, id: u32, box_: *const f64) -> bool;
    fn cadaclysm_blacksmith_rtree_count(tree: *const RTree) -> u32;
    fn cadaclysm_blacksmith_rtree_bounds(tree: *const RTree, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_rtree_free(tree: *mut RTree);
    fn cadaclysm_blacksmith_rtree_search(tree: *const RTree, box_: *const f64) -> *mut RTreeHits;
    fn cadaclysm_blacksmith_rtree_within(tree: *const RTree, p: *const f64, r: f64) -> *mut RTreeHits;
    fn cadaclysm_blacksmith_rtree_nearest(tree: *const RTree, p: *const f64, k: u32) -> *mut RTreeHits;
    fn cadaclysm_blacksmith_rtree_ray(tree: *const RTree, origin: *const f64, direction: *const f64, max_t: f64) -> *mut RTreeHits;
    fn cadaclysm_blacksmith_rtree_hits_count(hits: *const RTreeHits) -> u32;
    fn cadaclysm_blacksmith_rtree_hits_at(hits: *const RTreeHits, i: u32, out: *mut CadaclysmBlacksmithRTreeHit) -> bool;
    fn cadaclysm_blacksmith_rtree_hits_free(hits: *mut RTreeHits);
    fn cadaclysm_blacksmith_rtree_overlaps(a: *const RTree, b: *const RTree, slack: f64) -> *mut RTreePairs;
    fn cadaclysm_blacksmith_rtree_self_overlaps(tree: *const RTree, slack: f64) -> *mut RTreePairs;
    fn cadaclysm_blacksmith_rtree_pairs_count(pairs: *const RTreePairs) -> u32;
    fn cadaclysm_blacksmith_rtree_pairs_at(pairs: *const RTreePairs, i: u32, out: *mut CadaclysmBlacksmithRTreePair) -> bool;
    fn cadaclysm_blacksmith_rtree_pairs_free(pairs: *mut RTreePairs);
    fn cadaclysm_blacksmith_interpolator_new(samples: *const f64, count: u32, dimension: u32, cyclic: bool) -> *mut Interpolator;
    fn cadaclysm_blacksmith_interpolator_count(interpolator: *const Interpolator) -> u32;
    fn cadaclysm_blacksmith_interpolator_dimension(interpolator: *const Interpolator) -> u32;
    fn cadaclysm_blacksmith_interpolator_cyclic(interpolator: *const Interpolator) -> bool;
    fn cadaclysm_blacksmith_interpolator_at(interpolator: *const Interpolator, t: f64, mode: u32, out: *mut f64, out_len: u32) -> bool;
    fn cadaclysm_blacksmith_interpolator_sample(interpolator: *const Interpolator, ts: *const f64, n: u32, mode: u32, out: *mut f64, out_len: u32) -> bool;
    fn cadaclysm_blacksmith_interpolator_free(interpolator: *mut Interpolator);
    fn cadaclysm_blacksmith_contains(solid: *const Solid, point: *const f64, tolerance: f64, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_closest(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void, out: *mut CadaclysmBlacksmithClosest) -> bool;
    fn cadaclysm_blacksmith_closest_point(solid: *const Solid, p: *const f64, max_distance: f64, tolerance: f64, out: *mut CadaclysmBlacksmithPointFoot) -> i32;
    fn cadaclysm_blacksmith_projector_new(solid: *const Solid, tolerance: f64) -> *mut Projector;
    fn cadaclysm_blacksmith_projector_closest_point(projector: *const Projector, p: *const f64, max_distance: f64, out: *mut CadaclysmBlacksmithPointFoot) -> i32;
    fn cadaclysm_blacksmith_projector_free(projector: *mut Projector);
    fn cadaclysm_blacksmith_face_closest_point(solid: *const Solid, face: u32, p: *const f64, out: *mut CadaclysmBlacksmithPointFoot) -> i32;
    fn cadaclysm_blacksmith_edge_closest_point(solid: *const Solid, edge: u32, p: *const f64, out: *mut f64) -> i32;
    fn cadaclysm_blacksmith_nurbs_curve_closest_point(curve: *const NurbsCurve, p: *const f64, out: *mut f64) -> i32;
    fn cadaclysm_blacksmith_nurbs_curve_closest_point_within(curve: *const NurbsCurve, p: *const f64, max_distance: f64, out: *mut f64) -> i32;
    fn cadaclysm_blacksmith_nurbs_curve_closest_points(a: *const NurbsCurve, b: *const NurbsCurve, max_distance: f64, out: *mut CadaclysmBlacksmithCurvePair) -> i32;
    fn cadaclysm_blacksmith_curve_closest_points(solid: *const Solid, curve: *const NurbsCurve, max_distance: f64, tolerance: f64, out: *mut CadaclysmBlacksmithCurveBodyFoot) -> i32;
    fn cadaclysm_blacksmith_projector_curve_closest_points(projector: *const Projector, curve: *const NurbsCurve, max_distance: f64, out: *mut CadaclysmBlacksmithCurveBodyFoot) -> i32;
    fn cadaclysm_blacksmith_nurbs_curve_closest_object(curve: *const NurbsCurve, kinds: *const u8, count: u32, solids: *const *const Solid, n_solids: u32, curves: *const *const NurbsCurve, n_curves: u32, points: *const f64, n_points: u32, projectors: *const *const Projector, n_projectors: u32, meshes: *const *const TriangleMesh, n_meshes: u32, max_distance: f64, tolerance: f64, out: *mut CadaclysmBlacksmithNearestObject) -> i32;
    fn cadaclysm_blacksmith_triangle_mesh_new(positions: *const f64, vertex_count: u32, indices: *const u32, triangle_count: u32) -> *mut TriangleMesh;
    fn cadaclysm_blacksmith_solid_triangle_mesh(solid: *const Solid, tolerance: f64) -> *mut TriangleMesh;
    fn cadaclysm_blacksmith_triangle_mesh_free(mesh: *mut TriangleMesh);
    fn cadaclysm_blacksmith_triangle_mesh_vertex_count(mesh: *const TriangleMesh) -> u32;
    fn cadaclysm_blacksmith_triangle_mesh_triangle_count(mesh: *const TriangleMesh) -> u32;
    fn cadaclysm_blacksmith_triangle_mesh_bounds(mesh: *const TriangleMesh, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_triangle_mesh_closest_point(mesh: *const TriangleMesh, p: *const f64, max_distance: f64, out: *mut CadaclysmBlacksmithMeshPoint) -> i32;
    fn cadaclysm_blacksmith_triangle_mesh_curve_closest_points(mesh: *const TriangleMesh, curve: *const NurbsCurve, max_distance: f64, out: *mut CadaclysmBlacksmithCurveMeshFoot) -> i32;
    // Mechanical drawings: hidden-line removal, the projected outline, the page and DXF profiles.
    fn cadaclysm_blacksmith_hlr_options_init(options: *mut CadaclysmBlacksmithHlrOptions);
    fn cadaclysm_blacksmith_hlr(solids: *const *const Solid, count: usize, options: *const CadaclysmBlacksmithHlrOptions) -> *mut Hlr;
    fn cadaclysm_blacksmith_hlr_mesh(meshes: *const *const TriangleMesh, count: usize, options: *const CadaclysmBlacksmithHlrOptions) -> *mut Hlr;
    fn cadaclysm_blacksmith_hlr_line_count(hlr: *const Hlr) -> u32;
    fn cadaclysm_blacksmith_hlr_line(hlr: *const Hlr, i: u32, out: *mut CadaclysmBlacksmithHlrLine) -> bool;
    fn cadaclysm_blacksmith_hlr_line_beziers2d(hlr: *const Hlr, i: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_hlr_line_beziers3d(hlr: *const Hlr, i: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_hlr_report(hlr: *const Hlr, out: *mut CadaclysmBlacksmithHlrReport) -> bool;
    fn cadaclysm_blacksmith_hlr_free(hlr: *mut Hlr);
    fn cadaclysm_blacksmith_projected_outline(solids: *const *const Solid, count: usize, options: *const CadaclysmBlacksmithHlrOptions) -> *mut ProfileList;
    fn cadaclysm_blacksmith_page_new(units: u32) -> *mut Page;
    fn cadaclysm_blacksmith_page_add_view(page: *mut Page, hlr: *const Hlr, x: f64, y: f64, scale: f64) -> bool;
    fn cadaclysm_blacksmith_page_add_profile(page: *mut Page, profile: *const Profile, layer: *const c_char, x: f64, y: f64) -> bool;
    fn cadaclysm_blacksmith_page_add_hatch(page: *mut Page, profile: *const Profile, layer: *const c_char, pattern: *const c_char, angle: f64, scale: f64, x: f64, y: f64) -> bool;
    fn cadaclysm_blacksmith_page_add_text(page: *mut Page, text: *const c_char, layer: *const c_char, x: f64, y: f64, height: f64, angle: f64, halign: *const c_char, valign: *const c_char) -> bool;
    fn cadaclysm_blacksmith_page_entity_count(page: *const Page) -> u32;
    fn cadaclysm_blacksmith_page_svg_text(page: *const Page) -> *mut c_char;
    fn cadaclysm_blacksmith_page_dxf_text(page: *const Page) -> *mut c_char;
    fn cadaclysm_blacksmith_page_free(page: *mut Page);
    fn cadaclysm_blacksmith_dxf_profiles(text: *const c_char, tolerance: f64) -> *mut ProfileList;
    fn cadaclysm_blacksmith_mesh(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithMesh;
    fn cadaclysm_blacksmith_mesh64(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithMesh64;
    fn cadaclysm_blacksmith_mesh_face_triangles(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithFaceTriangles;
    fn cadaclysm_blacksmith_edge_polylines(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithPolylines;
    fn cadaclysm_blacksmith_edge_polyline_colours(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithColours;
    // A held tessellation: declared to match the header for parity, unused by the SDK's
    // own borrow-checked API (`crate::blacksmith`), which keeps `&mut self` views borrowed
    // from the solid instead.
    fn cadaclysm_blacksmith_tessellation(solid: *const Solid, tolerance: f64) -> *mut Tessellation;
    fn cadaclysm_blacksmith_tessellation_free(tessellation: *mut Tessellation);
    fn cadaclysm_blacksmith_tessellation_mesh(tessellation: *const Tessellation) -> CadaclysmBlacksmithMesh;
    fn cadaclysm_blacksmith_tessellation_mesh64(tessellation: *const Tessellation) -> CadaclysmBlacksmithMesh64;
    fn cadaclysm_blacksmith_tessellation_face_triangles(tessellation: *const Tessellation) -> CadaclysmBlacksmithFaceTriangles;
    fn cadaclysm_blacksmith_tessellation_edge_polylines(tessellation: *const Tessellation) -> CadaclysmBlacksmithPolylines;
    fn cadaclysm_blacksmith_bounds(solid: *const Solid, tolerance: f64, min: *mut f64, max: *mut f64) -> bool;
    fn cadaclysm_blacksmith_bounds64(solid: *const Solid, tolerance: f64, min: *mut f64, max: *mut f64) -> bool;
    fn cadaclysm_blacksmith_box(solid: *const Solid, min: *mut f64, max: *mut f64) -> bool;
    fn cadaclysm_blacksmith_step(solids: *const *const Solid, count: usize, schema: *const c_char, unit: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_sat_text(solids: *const *const Solid, count: usize, unit: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_sat(solids: *const *const Solid, count: usize, path: *const c_char, unit: u32) -> bool;
    // A `.3dm`: OWNED bytes, `*len` of them, freed with `bytes_free` and that same length --
    // never `string_free`. On success a non-null `last_error` holds the writer's notes.
    fn cadaclysm_blacksmith_3dm_bytes(solids: *const *const Solid, count: usize, unit: u32, len: *mut usize) -> *mut u8;
    // The solids' meshes as one STL, OBJ or glTF file: OWNED bytes, freed with `bytes_free`.
    // `names` NULL or `count` strings; `looks` NULL or six doubles a solid.
    fn cadaclysm_blacksmith_mesh_file(
        solids: *const *const Solid,
        count: usize,
        format: *const c_char,
        names: *const *const c_char,
        looks: *const f64,
        tolerance: f64,
        len: *mut usize
    ) -> *mut u8;
    fn cadaclysm_blacksmith_3dm(solids: *const *const Solid, count: usize, path: *const c_char, unit: u32) -> bool;
    fn cadaclysm_blacksmith_assembly_3dm_bytes(assembly: *const Assembly, unit: u32, len: *mut usize) -> *mut u8;
    fn cadaclysm_blacksmith_assembly_3dm(assembly: *const Assembly, path: *const c_char, unit: u32) -> bool;
    fn cadaclysm_blacksmith_bytes_free(bytes: *mut u8, len: usize);
    fn cadaclysm_blacksmith_brep_text(solids: *const *const Solid, count: usize) -> *mut c_char;
    fn cadaclysm_blacksmith_brep(solids: *const *const Solid, count: usize, path: *const c_char) -> bool;
    fn cadaclysm_blacksmith_svg_options_init(options: *mut CadaclysmBlacksmithSvgOptions);
    fn cadaclysm_blacksmith_svg_text(solids: *const *const Solid, count: usize, options: *const CadaclysmBlacksmithSvgOptions) -> *mut c_char;
    fn cadaclysm_blacksmith_svg(solids: *const *const Solid, count: usize, path: *const c_char, options: *const CadaclysmBlacksmithSvgOptions) -> bool;
    // A solid's silhouette, an OWNED block of `count * 16` doubles (a segment's four control
    // points' x, y, z, then its four weights), freed with the `_free` beside it, handing back
    // the `count` the call wrote. See `Solid::silhouette_beziers`, which does both.
    fn cadaclysm_blacksmith_silhouette_beziers(solid: *const Solid, options: *const CadaclysmBlacksmithSvgOptions, count: *mut u32) -> *mut f64;
    fn cadaclysm_blacksmith_silhouette_beziers_free(data: *mut f64, count: u32);
    fn cadaclysm_blacksmith_fem_options_init(options: *mut CadaclysmBlacksmithFemOptions);
    fn cadaclysm_blacksmith_fem_mesh(
        solid: *const Solid,
        placement: *const f64,
        options: *const CadaclysmBlacksmithFemOptions,
        progress: Progress,
        user: *mut c_void
    ) -> *mut Fem;
    fn cadaclysm_blacksmith_fem_mesh_view(m: *const Fem, out: *mut CadaclysmBlacksmithFemMeshView) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_edge(m: *const Fem, i: u32, out: *mut CadaclysmBlacksmithFemEdge) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_vertex(m: *const Fem, i: u32, out: *mut CadaclysmBlacksmithFemVertex) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_open_edge(m: *const Fem, i: u32, a: *mut u32, b: *mut u32, brep_edge: *mut u32) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_folded_edge(m: *const Fem, i: u32, a: *mut u32, b: *mut u32, brep_edge: *mut u32) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_crossing_count(m: *const Fem) -> u32;
    fn cadaclysm_blacksmith_fem_mesh_crossing(m: *const Fem, i: u32, a: *mut u32, b: *mut u32) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_msh_text(m: *const Fem) -> *mut c_char;
    fn cadaclysm_blacksmith_fem_mesh_save_msh(m: *const Fem, path: *const c_char) -> bool;
    fn cadaclysm_blacksmith_fem_mesh_free(m: *mut Fem);
    // The additive pair a drawing takes solids and profiles together through -- see
    // `crate::blacksmith::svg_text_of`/`svg_of`.
    fn cadaclysm_blacksmith_drawing_svg_text(
        solids: *const *const Solid,
        solid_count: usize,
        profiles: *const *const Profile,
        profile_count: usize,
        options: *const CadaclysmBlacksmithSvgOptions
    ) -> *mut c_char;
    fn cadaclysm_blacksmith_drawing_svg(
        solids: *const *const Solid,
        solid_count: usize,
        profiles: *const *const Profile,
        profile_count: usize,
        path: *const c_char,
        options: *const CadaclysmBlacksmithSvgOptions
    ) -> bool;

    fn cadaclysm_blacksmith_named(solid: *const Solid, name: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_name(solid: *const Solid) -> *const c_char;
    fn cadaclysm_blacksmith_with_material(solid: *const Solid, material: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_material(solid: *const Solid) -> *const c_char;
    fn cadaclysm_blacksmith_styled(solid: *const Solid, location: *const c_char, identification: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_solid_style_location(solid: *const Solid) -> *const c_char;
    fn cadaclysm_blacksmith_solid_style_identification(solid: *const Solid) -> *const c_char;
    fn cadaclysm_blacksmith_assembly_new(name: *const c_char) -> *mut Assembly;
    fn cadaclysm_blacksmith_assembly_free(assembly: *mut Assembly);
    fn cadaclysm_blacksmith_assembly_name(assembly: *const Assembly) -> *const c_char;
    fn cadaclysm_blacksmith_assembly_place_solid(
        assembly: *mut Assembly,
        solid: *const Solid,
        frame: *const f64,
        name: *const c_char
    ) -> *mut c_char;
    fn cadaclysm_blacksmith_assembly_place_assembly(
        assembly: *mut Assembly,
        placed: *const Assembly,
        frame: *const f64,
        name: *const c_char
    ) -> *mut c_char;
    fn cadaclysm_blacksmith_assembly_step(assembly: *const Assembly, schema: *const c_char, unit: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_assembly_link(
        assembly: *mut Assembly,
        name: *const c_char,
        placements: *const *const c_char,
        placement_count: usize
    ) -> bool;
    fn cadaclysm_blacksmith_assembly_joint(assembly: *mut Assembly, name: *const c_char, start: *const c_char, end: *const c_char) -> bool;
    // Blacksmith pairs: a joint's pair, a named mechanism state, and an assembly's base link.
    fn cadaclysm_blacksmith_assembly_pair(
        assembly: *mut Assembly,
        joint: *const c_char,
        kind: *const c_char,
        frame: *const f64,
        end_frame: *const f64,
        lower: *const f64,
        upper: *const f64,
        has_lower: *const bool,
        has_upper: *const bool,
        freedom_count: usize,
        pitch: f64
    ) -> bool;
    fn cadaclysm_blacksmith_assembly_pair_with(
        assembly: *mut Assembly,
        joint: *const c_char,
        kind: *const c_char,
        frame: *const f64,
        end_frame: *const f64,
        lower: *const f64,
        upper: *const f64,
        has_lower: *const bool,
        has_upper: *const bool,
        freedom_count: usize,
        params: *const f64,
        param_count: usize
    ) -> bool;
    fn cadaclysm_blacksmith_assembly_state(
        assembly: *mut Assembly,
        name: *const c_char,
        joints: *const *const c_char,
        counts: *const u32,
        values: *const f64,
        row_count: usize
    ) -> bool;
    fn cadaclysm_blacksmith_assembly_posed(
        assembly: *const Assembly,
        joints: *const *const c_char,
        counts: *const u32,
        values: *const f64,
        row_count: usize,
        state: *const c_char,
        ground: *const c_char
    ) -> *mut Assembly;
    fn cadaclysm_blacksmith_assembly_part_count(assembly: *const Assembly) -> u32;
    fn cadaclysm_blacksmith_assembly_part_path(assembly: *const Assembly, i: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_assembly_swept_clash(
        assembly: *const Assembly,
        joints: *const *const c_char,
        counts: *const u32,
        joint_count: usize,
        values: *const f64,
        key_count: u32,
        ground: *const c_char,
        tolerance: f64,
        clearance: f64,
        resolution: f64,
        max_steps: u32,
        allowed: *const u32,
        allowed_count: u32,
        joined: bool
    ) -> *mut SweptClashes;
    fn cadaclysm_blacksmith_assembly_sequence(
        assembly: *mut Assembly,
        name: *const c_char,
        states: *const *const c_char,
        ts: *const f64,
        interpolations: *const *const c_char,
        count: usize,
        seconds: bool
    ) -> bool;
    fn cadaclysm_blacksmith_assembly_base(assembly: *mut Assembly, link: *const c_char) -> bool;
    fn cadaclysm_blacksmith_pair_freedom_count(kind: *const c_char) -> u32;

    fn cadaclysm_blacksmith_solid_bounds_box(solid: *const Solid, tolerance: f64, out: *mut BoxShape) -> bool;
    fn cadaclysm_blacksmith_box_moved(box_: *const BoxShape, frame: *const f64, out: *mut BoxShape) -> bool;
    fn cadaclysm_blacksmith_box_overlaps(a: *const BoxShape, b: *const BoxShape) -> bool;
    fn cadaclysm_blacksmith_boxes_apart(a: *const BoxShape, frame_a: *const f64, b: *const BoxShape, frame_b: *const f64, apart: *mut bool) -> bool;
    fn cadaclysm_blacksmith_collider_new(
        solids: *const *const Solid,
        count: u32,
        tolerance: f64,
        groups: *const u32,
        allowed: *const u32,
        allowed_count: u32
    ) -> *mut Collider;
    fn cadaclysm_blacksmith_collider_free(collider: *mut Collider);
    fn cadaclysm_blacksmith_collider_group_count(collider: *const Collider) -> u32;
    fn cadaclysm_blacksmith_collider_stats(collider: *const Collider, out: *mut CadaclysmBlacksmithColliderStats) -> bool;
    fn cadaclysm_blacksmith_collider_check(
        collider: *mut Collider,
        frames: *const f64,
        frame_count: u32,
        share_k: u32,
        share_n: u32
    ) -> *mut Collisions;
    fn cadaclysm_blacksmith_collisions_free(collisions: *mut Collisions);
    fn cadaclysm_blacksmith_collisions_count(collisions: *const Collisions) -> u32;
    fn cadaclysm_blacksmith_collisions_hit(collisions: *const Collisions, i: u32, out: *mut CadaclysmBlacksmithCollisionHit) -> bool;
    fn cadaclysm_blacksmith_collisions_solid(collisions: *const Collisions, i: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_collider_clash(
        collider: *mut Collider,
        frames: *const f64,
        frame_count: u32,
        clearance: f64,
        share_k: u32,
        share_n: u32
    ) -> *mut Clashes;
    fn cadaclysm_blacksmith_clash(
        a: *const *const Solid,
        a_count: u32,
        b: *const *const Solid,
        b_count: u32,
        tolerance: f64,
        clearance: f64,
        allowed: *const u32,
        allowed_count: u32
    ) -> *mut Clashes;
    fn cadaclysm_blacksmith_clashes_free(clashes: *mut Clashes);
    fn cadaclysm_blacksmith_clashes_count(clashes: *const Clashes) -> u32;
    fn cadaclysm_blacksmith_clashes_at(clashes: *const Clashes, i: u32, out: *mut CadaclysmBlacksmithClash) -> bool;
    fn cadaclysm_blacksmith_clashes_solid(clashes: *const Clashes, i: u32) -> *mut Solid;
    fn cadaclysm_blacksmith_clashes_intersect(clashes: *const Clashes, i: u32) -> *mut Intersection;
    fn cadaclysm_blacksmith_collider_swept_clash(
        collider: *mut Collider,
        poses: *const f64,
        pose_count: u32,
        frame_count: u32,
        clearance: f64,
        resolution: f64,
        max_steps: u32,
        share_k: u32,
        share_n: u32
    ) -> *mut SweptClashes;
    fn cadaclysm_blacksmith_swept_clash(
        a: *const *const Solid,
        a_count: u32,
        poses_a: *const f64,
        b: *const *const Solid,
        b_count: u32,
        poses_b: *const f64,
        pose_count: u32,
        tolerance: f64,
        clearance: f64,
        resolution: f64,
        max_steps: u32,
        allowed: *const u32,
        allowed_count: u32
    ) -> *mut SweptClashes;
    fn cadaclysm_blacksmith_swept_clashes_free(swept: *mut SweptClashes);
    fn cadaclysm_blacksmith_swept_clashes_count(swept: *const SweptClashes) -> u32;
    fn cadaclysm_blacksmith_swept_clashes_at(swept: *const SweptClashes, i: u32, out: *mut CadaclysmBlacksmithSweptClash) -> bool;
    fn cadaclysm_blacksmith_swept_clashes_interval(swept: *const SweptClashes, i: u32, k: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_swept_clashes_firsts(swept: *const SweptClashes) -> *mut Clashes;

    fn cadaclysm_blacksmith_thickness_gauge_new(solids: *const *const Solid, count: u32, tolerance: f64) -> *mut ThicknessGauge;
    fn cadaclysm_blacksmith_thickness_gauge_free(gauge: *mut ThicknessGauge);
    fn cadaclysm_blacksmith_thickness_gauge_body_count(gauge: *const ThicknessGauge) -> u32;
    fn cadaclysm_blacksmith_thickness_gauge_tolerance(gauge: *const ThicknessGauge) -> f64;
    fn cadaclysm_blacksmith_thickness_gauge_mesh(gauge: *const ThicknessGauge, body: u32, out: *mut CadaclysmBlacksmithThicknessMesh) -> bool;
    fn cadaclysm_blacksmith_thickness_gauge_measure(gauge: *const ThicknessGauge, maximum: f64, sharp_angle: f64) -> *mut Thicknesses;
    fn cadaclysm_blacksmith_thickness_gauge_at(
        gauge: *const ThicknessGauge,
        body: u32,
        face: u32,
        point: *const f64,
        maximum: f64,
        sharp_angle: f64
    ) -> *mut Thicknesses;
    fn cadaclysm_blacksmith_thickness_gauge_face(
        gauge: *const ThicknessGauge,
        body: u32,
        face: u32,
        at: *const f64,
        maximum: f64,
        out: *mut CadaclysmBlacksmithFaceThickness
    ) -> bool;
    fn cadaclysm_blacksmith_thicknesses_free(list: *mut Thicknesses);
    fn cadaclysm_blacksmith_thicknesses_count(list: *const Thicknesses) -> u32;
    fn cadaclysm_blacksmith_thicknesses_at(list: *const Thicknesses, i: u32, out: *mut CadaclysmBlacksmithThickness) -> bool;
    fn cadaclysm_blacksmith_mesh_thickness(
        positions: *const f64,
        vertex_counts: *const u32,
        indices: *const u32,
        triangle_counts: *const u32,
        mesh_count: u32,
        maximum: f64,
        sharp_angle: f64
    ) -> *mut MeshThicknesses;
    fn cadaclysm_blacksmith_mesh_thicknesses_free(list: *mut MeshThicknesses);
    fn cadaclysm_blacksmith_mesh_thicknesses_count(list: *const MeshThicknesses) -> u32;
    fn cadaclysm_blacksmith_mesh_thicknesses_at(list: *const MeshThicknesses, i: u32, out: *mut CadaclysmBlacksmithMeshThickness) -> bool;

    fn cadaclysm_blacksmith_subd_cuboid(sx: f64, sy: f64, sz: f64, nx: u32, ny: u32, nz: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_cylinder(radius: f64, height: f64, sides: u32, rings: u32, creased_rims: bool) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_sphere(radius: f64, segments: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_torus(major: f64, minor: f64, around: u32, tube: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_from_parts(
        positions: *const f64,
        vertex_count: u32,
        face_sizes: *const u32,
        face_count: u32,
        face_indices: *const u32,
        index_count: u32,
        creases: *const u32,
        crease_count: u32,
        pins: *const u32,
        pin_count: u32,
        symmetry_axis: i32,
        symmetry_tolerance: f64
    ) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_parts(subd: *const Subd, out: *mut CadaclysmBlacksmithSubdParts) -> bool;
    fn cadaclysm_blacksmith_subd_free(subd: *mut Subd);
    fn cadaclysm_blacksmith_subd_transform(subd: *const Subd, kind: u32, ids: *const u32, id_count: u32, matrix: *const f64) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_set_crease(subd: *const Subd, edges: *const u32, edge_count: u32, on: bool) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_set_pin(subd: *const Subd, vertices: *const u32, vertex_count: u32, on: bool) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_extrude(subd: *const Subd, faces: *const u32, face_count: u32, distance: f64) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_inset(subd: *const Subd, faces: *const u32, face_count: u32, amount: f64, individual: bool) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_subdivide(subd: *const Subd, faces: *const u32, face_count: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_insert_loop(subd: *const Subd, a: u32, b: u32, at: f64) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_mirror_on(subd: *const Subd, axis: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_mirror_off(subd: *const Subd) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_full(subd: *const Subd) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_edge_loop(subd: *const Subd, a: u32, b: u32) -> *mut Subd;
    fn cadaclysm_blacksmith_subd_smooth_mesh(subd: *const Subd, levels: u32, out: *mut CadaclysmBlacksmithSubdMesh) -> bool;
    fn cadaclysm_blacksmith_subd_pick(subd: *const Subd, point: *const f64, kind: u32, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_subd_to_solid(
        subd: *const Subd,
        tolerance: f64,
        g1_angle_deg: f64,
        max_levels: u32,
        report: *mut CadaclysmBlacksmithSubdReport
    ) -> *mut Solid;

    fn cadaclysm_blacksmith_sketch_new() -> *mut Sketch;
    fn cadaclysm_blacksmith_sketch_free(s: *mut Sketch);
    fn cadaclysm_blacksmith_sketch_from_profile(profile: *const Profile, infer: bool, tolerance: f64) -> *mut Sketch;
    fn cadaclysm_blacksmith_sketch_add_point(s: *mut Sketch, x: f64, y: f64) -> u32;
    fn cadaclysm_blacksmith_sketch_add_line(s: *mut Sketch, a: u32, b: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_add_circle(s: *mut Sketch, centre: u32, r: f64) -> u32;
    fn cadaclysm_blacksmith_sketch_add_arc(s: *mut Sketch, centre: u32, start: u32, end: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_add_bezier(s: *mut Sketch, start: u32, c1x: f64, c1y: f64, c2x: f64, c2y: f64, x: f64, y: f64) -> u32;
    fn cadaclysm_blacksmith_sketch_add_conic(s: *mut Sketch, start: u32, cx: f64, cy: f64, x: f64, y: f64, weight: f64) -> u32;
    fn cadaclysm_blacksmith_sketch_add_nurbs(s: *mut Sketch, start: u32, degree: u32, xy: *const f64, count: usize, weights: *const f64, knots: *const f64, knot_count: usize) -> u32;
    fn cadaclysm_blacksmith_sketch_add_rect(s: *mut Sketch, x0: f64, y0: f64, x1: f64, y1: f64, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_kind(s: *const Sketch, id: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_entities(s: *mut Sketch, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_point(s: *const Sketch, id: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_set_point(s: *mut Sketch, id: u32, x: f64, y: f64) -> bool;
    fn cadaclysm_blacksmith_sketch_radius(s: *const Sketch, id: u32) -> f64;
    fn cadaclysm_blacksmith_sketch_set_radius(s: *mut Sketch, id: u32, r: f64) -> bool;
    fn cadaclysm_blacksmith_sketch_centre(s: *const Sketch, id: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_ends(s: *mut Sketch, id: u32, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_set_construction(s: *mut Sketch, id: u32, on: bool) -> bool;
    fn cadaclysm_blacksmith_sketch_is_construction(s: *const Sketch, id: u32) -> bool;
    fn cadaclysm_blacksmith_sketch_is_reference(s: *const Sketch, id: u32) -> bool;
    fn cadaclysm_blacksmith_sketch_remove_entity(s: *mut Sketch, id: u32, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_reference(s: *mut Sketch, other: *const Sketch, entity: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_update_reference(s: *mut Sketch, id: u32, other: *const Sketch, report: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_constrain(s: *mut Sketch, kind: u32, refs: *const u32, ref_count: usize, value: f64, driving: bool, sense: u32, end: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_constraints(s: *mut Sketch, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_constraint_kind(s: *const Sketch, id: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_constraint_refs(s: *mut Sketch, id: u32, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_constraint_value(s: *const Sketch, id: u32) -> f64;
    fn cadaclysm_blacksmith_sketch_constraint_driving(s: *const Sketch, id: u32) -> bool;
    fn cadaclysm_blacksmith_sketch_constraint_sense(s: *const Sketch, id: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_constraint_end(s: *const Sketch, id: u32) -> u32;
    fn cadaclysm_blacksmith_sketch_is_joint_tangent(s: *const Sketch, id: u32) -> bool;
    fn cadaclysm_blacksmith_sketch_remove(s: *mut Sketch, id: u32) -> bool;
    fn cadaclysm_blacksmith_sketch_set_value(s: *mut Sketch, id: u32, value: f64, report: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_set_driving(s: *mut Sketch, id: u32, driving: bool, report: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_measure(s: *const Sketch, id: u32) -> f64;
    fn cadaclysm_blacksmith_sketch_solve(s: *mut Sketch, report: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_drag(s: *mut Sketch, points: *const u32, xy: *const f64, count: usize, report: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_report_ids(s: *const Sketch, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_diagnose(s: *mut Sketch, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_dof_list(s: *mut Sketch, which: u32, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_dof_part(s: *const Sketch, part: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_sketch_dof_part_list(s: *mut Sketch, part: u32, which: u32, count: *mut usize) -> *const u32;
    fn cadaclysm_blacksmith_sketch_profiles(s: *const Sketch, tolerance: f64) -> *mut ProfileList;
    fn cadaclysm_blacksmith_sketch_open_chains(s: *const Sketch, tolerance: f64) -> *mut ProfileList;

    fn cadaclysm_blacksmith_tool_flat(number: u32, diameter: f64, flute_length: f64, feed: f64, plunge: f64, rpm: f64) -> *mut Tool;
    fn cadaclysm_blacksmith_tool_ball(number: u32, diameter: f64, flute_length: f64, feed: f64, plunge: f64, rpm: f64) -> *mut Tool;
    fn cadaclysm_blacksmith_tool_drill(number: u32, diameter: f64, flute_length: f64, feed: f64, rpm: f64) -> *mut Tool;
    fn cadaclysm_blacksmith_tool_with_ramp_angle(t: *const Tool, degrees: f64) -> *mut Tool;
    fn cadaclysm_blacksmith_tool_free(t: *mut Tool);

    fn cadaclysm_blacksmith_stock_box(min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) -> *mut Stock;
    fn cadaclysm_blacksmith_stock_around(solid: *const Solid, margin: f64) -> *mut Stock;
    fn cadaclysm_blacksmith_stock_free(s: *mut Stock);

    fn cadaclysm_blacksmith_job_new(stock: *const Stock, safe_z: f64) -> *mut Job;
    fn cadaclysm_blacksmith_job_set_clearance(j: *mut Job, clearance: f64) -> bool;
    fn cadaclysm_blacksmith_job_set_tolerance(j: *mut Job, tolerance: f64) -> bool;
    fn cadaclysm_blacksmith_job_set_spindle_dwell(j: *mut Job, seconds: f64) -> bool;
    fn cadaclysm_blacksmith_job_set_name(j: *mut Job, name: *const c_char) -> bool;
    fn cadaclysm_blacksmith_job_set_resolution(j: *mut Job, resolution: f64) -> bool;
    fn cadaclysm_blacksmith_job_face(j: *mut Job, t: *const Tool, z: f64, stepover: f64, stepdown: f64) -> bool;
    fn cadaclysm_blacksmith_job_contour(
        j: *mut Job,
        t: *const Tool,
        p: *const Profile,
        top: f64,
        bottom: f64,
        side: u32,
        stepdown: f64,
        climb: bool,
        open: bool
    ) -> bool;
    fn cadaclysm_blacksmith_job_pocket(j: *mut Job, t: *const Tool, p: *const Profile, top: f64, bottom: f64, stepover: f64, stepdown: f64) -> bool;
    fn cadaclysm_blacksmith_job_drill(j: *mut Job, t: *const Tool, xy: *const f64, count: usize, top: f64, bottom: f64, peck: f64) -> bool;
    fn cadaclysm_blacksmith_job_gcode(j: *const Job) -> *mut Programs;
    fn cadaclysm_blacksmith_job_camotics(j: *const Job, stem: *const c_char) -> *mut Programs;
    fn cadaclysm_blacksmith_job_free(j: *mut Job);

    fn cadaclysm_blacksmith_programs_count(l: *const Programs) -> u32;
    fn cadaclysm_blacksmith_programs_tool(l: *const Programs, i: u32) -> u32;
    fn cadaclysm_blacksmith_programs_name(l: *const Programs, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_programs_text(l: *const Programs, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_programs_free(l: *mut Programs);

    fn cadaclysm_blacksmith_job_machine(
        j: *mut Job,
        part: *const Solid,
        end_mill: *const Tool,
        drills: *const *const Tool,
        drill_count: usize,
        stepover: f64,
        stepdown: f64,
        skin: f64,
        peck: f64
    ) -> *mut Report;
    fn cadaclysm_blacksmith_job_machine_with(
        j: *mut Job,
        part: *const Solid,
        end_mills: *const *const Tool,
        end_mill_count: usize,
        drills: *const *const Tool,
        drill_count: usize,
        stepover: f64,
        stepdown: f64,
        skin: f64,
        peck: f64
    ) -> *mut Report;
    fn cadaclysm_blacksmith_job_machine_relieved(
        j: *mut Job,
        part: *const Solid,
        end_mills: *const *const Tool,
        end_mill_count: usize,
        drills: *const *const Tool,
        drill_count: usize,
        stepover: f64,
        stepdown: f64,
        skin: f64,
        peck: f64,
        corner_relief: bool
    ) -> *mut Report;
    fn cadaclysm_blacksmith_report_top(r: *const Report, i: u32) -> f64;
    fn cadaclysm_blacksmith_report_bottom(r: *const Report, i: u32) -> f64;
    fn cadaclysm_blacksmith_report_count(r: *const Report) -> u32;
    fn cadaclysm_blacksmith_report_kind(r: *const Report, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_report_at(r: *const Report, i: u32, out: *mut f64) -> bool;
    fn cadaclysm_blacksmith_report_size(r: *const Report, i: u32) -> f64;
    fn cadaclysm_blacksmith_report_reason(r: *const Report, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_report_region(r: *const Report, i: u32) -> *mut ProfileList;
    fn cadaclysm_blacksmith_report_text(r: *const Report) -> *const c_char;
    fn cadaclysm_blacksmith_report_free(r: *mut Report);

    fn cadaclysm_blacksmith_job_operations(j: *const Job) -> *mut Operations;
    fn cadaclysm_blacksmith_operations_count(l: *const Operations) -> u32;
    fn cadaclysm_blacksmith_operations_kind(l: *const Operations, i: u32) -> *const c_char;
    fn cadaclysm_blacksmith_operations_tool(l: *const Operations, i: u32) -> u32;
    fn cadaclysm_blacksmith_operations_param_count(l: *const Operations, i: u32) -> u32;
    fn cadaclysm_blacksmith_operations_param_name(l: *const Operations, i: u32, k: u32) -> *const c_char;
    fn cadaclysm_blacksmith_operations_param_value(l: *const Operations, i: u32, k: u32) -> f64;
    fn cadaclysm_blacksmith_operations_free(l: *mut Operations);

    fn cadaclysm_blacksmith_document_new(units: *const c_char) -> *mut Document;
    fn cadaclysm_blacksmith_document_load(text: *const c_char) -> *mut Document;
    fn cadaclysm_blacksmith_document_free(doc: *mut Document);
    fn cadaclysm_blacksmith_document_save(doc: *const Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_apply(doc: *mut Document, op: *const c_char, message: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_undo(doc: *mut Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_redo(doc: *mut Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_params(doc: *const Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_evaluate(doc: *mut Document, cheap_only: bool) -> *mut c_char;
    fn cadaclysm_blacksmith_document_evaluate_with(doc: *mut Document, cheap_only: bool, progress: DocumentProgress, user: *mut c_void) -> *mut c_char;
    fn cadaclysm_blacksmith_document_result_kind(doc: *const Document, id: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_result_solid(doc: *const Document, id: *const c_char) -> *mut Solid;
    fn cadaclysm_blacksmith_document_result_profile(doc: *const Document, id: *const c_char) -> *mut Profile;
    fn cadaclysm_blacksmith_document_result_profile_count(doc: *const Document, id: *const c_char) -> u32;
    fn cadaclysm_blacksmith_document_result_profile_at(doc: *const Document, id: *const c_char, i: u32) -> *mut Profile;
    fn cadaclysm_blacksmith_document_value(doc: *const Document, id: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_errors(doc: *const Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_kinds() -> *mut c_char;
    fn cadaclysm_blacksmith_document_solid_body(solid: *const Solid) -> *mut c_char;
    fn cadaclysm_blacksmith_document_profile_path(profile: *const Profile) -> *mut c_char;
    fn cadaclysm_blacksmith_document_preview(doc: *mut Document, op: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_preview_begin(doc: *mut Document) -> bool;
    fn cadaclysm_blacksmith_document_end_preview(doc: *mut Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_batch_begin(doc: *mut Document, message: *const c_char) -> bool;
    fn cadaclysm_blacksmith_document_batch_end(doc: *mut Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_batch_abort(doc: *mut Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_result_nurbs_curve(doc: *const Document, id: *const c_char) -> *mut NurbsCurve;
    fn cadaclysm_blacksmith_document_result_subd(doc: *const Document, id: *const c_char) -> *mut Subd;
    fn cadaclysm_blacksmith_document_branch_new(doc: *mut Document, name: *const c_char, at: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_branch_switch(doc: *mut Document, name_or_commit_id: *const c_char) -> *mut c_char;
    fn cadaclysm_blacksmith_document_tips(doc: *const Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_branch_rename(doc: *mut Document, old: *const c_char, new_: *const c_char) -> bool;
    fn cadaclysm_blacksmith_document_branch_delete(doc: *mut Document, name: *const c_char) -> bool;
    fn cadaclysm_blacksmith_document_branch_list(doc: *const Document) -> *mut c_char;
    fn cadaclysm_blacksmith_document_log(doc: *const Document, branch: *const c_char) -> *mut c_char;
    fn cadaclysm_bim_document_new(units: *const c_char) -> *mut Document;
    fn cadaclysm_bim_document_load(text: *const c_char) -> *mut Document;
    fn cadaclysm_bim_kinds() -> *mut c_char;
    fn cadaclysm_bim_document_export_ifc(doc: *mut Document, options_json: *const c_char) -> *mut c_char;
}

// ---- loading --------------------------------------------------------------------

/// The libraries that carry the kernel, in the order they are looked for: the single
/// library's flavours that hold it, then the separate library of earlier releases. As
/// `cadaclysm-capi-rt`'s `KERNEL_STEMS`.
pub const LIBRARY_STEMS: &[&str] = &["cadaclysm", "cadaclysm_kernel_reader", "cadaclysm_kernel", "cadaclysm_blacksmith"];

#[cfg(not(target_arch = "wasm32"))]
static LIBRARY: Loader<Api> = Loader::new(
    LIBRARY_STEMS,
    &["CADACLYSM_BLACKSMITH_LIBRARY", "CADACLYSM_LIBRARY"],
    Half { feature: "kernel", what: "kernel", instead: "cadaclysm, cadaclysm_kernel_reader or cadaclysm_kernel" },
    Api::bind,
    ENTRY_POINTS,
);

/// The kernel library's file names on this platform, in the order they are looked for.
pub fn library_names() -> Vec<String> {
    LIBRARY_STEMS.iter().map(|stem| crate::loader::file_name(stem)).collect()
}

/// The first of [`library_names`]: the full flavour's file name on this platform.
pub fn library_name() -> String {
    library_names().remove(0)
}

/// Where the kernel library would be loaded from, without loading it: the reader's
/// search ([`crate::sys::find_library`]) for [`library_names`], under
/// `CADACLYSM_BLACKSMITH_LIBRARY` (the separate kernel library's variable) and then
/// `CADACLYSM_LIBRARY` (one library of any flavour). `CADACLYSM_LIBRARY` naming the
/// separate reader library, or a directory with none of the kernel's names, is passed
/// over, as it was the reader's alone before the single library.
///
/// A copy the process already holds comes first, ahead of all of these, when the library
/// is loaded ([`load`] without a path): see [`use_loaded`].
#[cfg(not(target_arch = "wasm32"))]
pub fn find_library() -> Result<PathBuf, String> {
    LIBRARY.find()
}

/// Load the kernel library at `path` once. Without a `path`, the copy the process already
/// holds (found by file name, as the View finds it) is bound if there is one, and only
/// otherwise is one loaded from where [`find_library`] finds it.
#[cfg(not(target_arch = "wasm32"))]
pub fn load(path: Option<&Path>) -> Result<&'static Api, String> {
    LIBRARY.load(path)
}

/// Bind the kernel library the process already holds -- an embedded Python's
/// `cadaclysm_blacksmith`, say -- and never load one: an error where none is held, or
/// where this crate already bound another copy.
#[cfg(not(target_arch = "wasm32"))]
pub fn use_loaded() -> Result<&'static Api, String> {
    LIBRARY.use_loaded()
}

/// The path the kernel library was loaded from, or `None` before anything loaded it.
#[cfg(not(target_arch = "wasm32"))]
pub fn loaded_path() -> Option<&'static Path> {
    LIBRARY.loaded_path()
}

/// The bound function table, loading the library on first use.
#[cfg(not(target_arch = "wasm32"))]
pub fn api() -> Result<&'static Api, String> {
    load(None)
}

// In the browser the table is the web package's, bound by `crate::web::load`: there is no
// file to find or load.

/// No file holds the kernel in the browser: the web package does ([`crate::web::load`]).
#[cfg(target_arch = "wasm32")]
pub fn find_library() -> Result<PathBuf, String> {
    Err(format!("{} is not a file in the browser: the kernel comes from the web package (cadaclysm_sdk::web::load)", library_name()))
}

/// The table over the web package once [`crate::web::load`] bound it; a path means nothing
/// in the browser and is refused.
#[cfg(target_arch = "wasm32")]
pub fn load(path: Option<&Path>) -> Result<&'static Api, String> {
    match path {
        Some(path) => Err(format!("{}: no library file can be loaded in the browser; use cadaclysm_sdk::web::load", path.display())),
        None => api(),
    }
}

/// The table over the web package once [`crate::web::load`] bound it.
#[cfg(target_arch = "wasm32")]
pub fn use_loaded() -> Result<&'static Api, String> {
    api()
}

/// Always `None` in the browser: the kernel is the web package, not a file.
#[cfg(target_arch = "wasm32")]
pub fn loaded_path() -> Option<&'static Path> {
    None
}

/// The table over the web package: an error until [`crate::web::load`] (or
/// [`crate::web::bind`]) bound one.
#[cfg(target_arch = "wasm32")]
pub fn api() -> Result<&'static Api, String> {
    crate::web::kernel_api()
}
