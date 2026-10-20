//! The kernel's raw C ABI: the structs of `include/cadaclysm_blacksmith.h` in Rust's
//! layout, and every entry point as a function pointer read out of
//! `cadaclysm_blacksmith` when it is loaded -- the kernel's twin of [`crate::sys`].
//!
//! The structs are transcribed by hand and pinned against the header, field by field,
//! by `cadaclysm-capi/tests/bindings.rs`. Everything here is `unsafe` and checks
//! nothing; the safe API is [`crate::blacksmith`].

use std::ffi::{c_char, c_void};
use std::path::{Path, PathBuf};

use crate::loader::{entry_points, Loader};

/// What the kernel returns for "none": no face selected, a count it could not take.
pub const CADACLYSM_BLACKSMITH_NONE: u32 = u32::MAX;

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

/// The crossing of two solids, from `cadaclysm_blacksmith_intersect`. Opaque; freed with
/// `cadaclysm_blacksmith_intersection_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithIntersection {
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

/// A SubD control cage. Opaque; freed with `cadaclysm_blacksmith_subd_free`.
#[repr(C)]
pub struct CadaclysmBlacksmithSubd {
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

/// `CadaclysmBlacksmithProgress`: `(phase, done, total, user)`, or null for none.
pub type CadaclysmBlacksmithProgress = Option<unsafe extern "C" fn(*const c_char, usize, usize, *mut c_void)>;

type Solid = CadaclysmBlacksmithSolid;
type Assembly = CadaclysmBlacksmithAssembly;
type Profile = CadaclysmBlacksmithProfile;
type Path2 = CadaclysmBlacksmithPath;
type SweepPath = CadaclysmBlacksmithSweepPath;
type Progress = CadaclysmBlacksmithProgress;
type Hits = CadaclysmBlacksmithHits;
type Intersection = CadaclysmBlacksmithIntersection;
type ProfileList = CadaclysmBlacksmithProfileList;
type Tool = CadaclysmBlacksmithTool;
type Stock = CadaclysmBlacksmithStock;
type Job = CadaclysmBlacksmithJob;
type Programs = CadaclysmBlacksmithPrograms;
type Report = CadaclysmBlacksmithReport;
type Operations = CadaclysmBlacksmithOperations;
type Fem = CadaclysmBlacksmithFemMesh;
type Collider = CadaclysmBlacksmithCollider;
type Collisions = CadaclysmBlacksmithCollisions;
type Subd = CadaclysmBlacksmithSubd;
type BoxShape = CadaclysmBlacksmithBox;
type Tessellation = CadaclysmBlacksmithTessellation;

entry_points! {
    Api, ENTRY_POINTS;
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
    fn cadaclysm_blacksmith_coloured(solid: *const Solid, face: u32, r: f64, g: f64, b: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_edges_coloured(solid: *const Solid, edges: *const u32, count: usize, r: f64, g: f64, b: f64) -> *mut Solid;

    fn cadaclysm_blacksmith_solid_section(solid: *const Solid, z: f64, tolerance: f64) -> *mut ProfileList;
    fn cadaclysm_blacksmith_join(a: *const Solid, b: *const Solid, tolerance: f64, progress: Progress, user: *mut c_void) -> *mut Solid;
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
    fn cadaclysm_blacksmith_intersection_free(intersection: *mut Intersection);
    fn cadaclysm_blacksmith_intersection_chain_count(intersection: *const Intersection) -> u32;
    fn cadaclysm_blacksmith_intersection_chain(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithChain) -> bool;
    fn cadaclysm_blacksmith_intersection_curve(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithCurve) -> bool;
    fn cadaclysm_blacksmith_intersection_overlap_count(intersection: *const Intersection) -> u32;
    fn cadaclysm_blacksmith_intersection_overlap(intersection: *const Intersection, i: u32, out: *mut CadaclysmBlacksmithOverlap) -> bool;
    fn cadaclysm_blacksmith_leaked_edges(solid: *const Solid, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_unpaired_edges(solid: *const Solid, tolerance: f64) -> u32;
    fn cadaclysm_blacksmith_manifold(solid: *const Solid, out: *mut u32) -> bool;
    fn cadaclysm_blacksmith_mass_properties(solid: *const Solid, accuracy: f64,
                                           out: *mut CadaclysmBlacksmithMassProperties) -> bool;
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
}

// ---- loading --------------------------------------------------------------------

static LIBRARY: Loader<Api> = Loader::new("cadaclysm_blacksmith", "CADACLYSM_BLACKSMITH_LIBRARY", Api::bind);

/// The kernel library's file name on this platform.
pub fn library_name() -> String {
    LIBRARY.file_name()
}

/// Where the kernel library would be loaded from, without loading it: the reader's
/// search ([`crate::sys::find_library`]) under `CADACLYSM_BLACKSMITH_LIBRARY`. The
/// reader's variable is never consulted -- the two are separate libraries.
pub fn find_library() -> Result<PathBuf, String> {
    LIBRARY.find()
}

/// Load the kernel library at `path` (or where [`find_library`] finds it), once.
pub fn load(path: Option<&Path>) -> Result<&'static Api, String> {
    LIBRARY.load(path)
}

/// The path the kernel library was loaded from, or `None` before anything loaded it.
pub fn loaded_path() -> Option<&'static Path> {
    LIBRARY.loaded_path()
}

/// The bound function table, loading the library on first use.
pub fn api() -> Result<&'static Api, String> {
    load(None)
}
