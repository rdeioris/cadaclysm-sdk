//! The raw C ABI: the structs of `include/cadaclysm.h` in Rust's layout, and every
//! entry point this crate uses as a function pointer read out of the library when it
//! is loaded.
//!
//! Nothing here links against `cadaclysm_capi`. The library is opened at run time with
//! [`libloading`], the way Python's ctypes and Node's koffi open it, so this crate
//! builds with no C toolchain, no import library and no build script, and a program
//! built with it starts even where the library is missing -- it fails at the first
//! call that needs it, with a message saying where it looked.
//!
//! The structs are transcribed by hand. `cadaclysm-capi/tests/bindings.rs` pins every
//! one of them against the header, field by field, because a transcription that drops
//! a field still compiles and still runs, and reads every field after the gap from the
//! wrong offset.
//!
//! Everything here is `unsafe` to call and nothing here checks anything. The safe API
//! in the crate root is built on it; reach for this module only for an entry point
//! that API does not cover yet.

use std::ffi::{c_char, c_int, c_void};
use std::path::{Path, PathBuf};

use crate::loader::{entry_points, Loader};

/// What the ABI returns for "no such node" -- `CADACLYSM_NONE`, `UINT32_MAX`.
pub const CADACLYSM_NONE: u32 = u32::MAX;

/// An open document. Opaque: only ever handled through a pointer.
#[repr(C)]
pub struct CadaclysmScene {
    _private: [u8; 0],
}

/// A body's exact B-rep, shared with the scene by reference count. Opaque.
#[repr(C)]
pub struct CadaclysmBrep {
    _private: [u8; 0],
}

/// A posed mechanism -- `Scene::pose` or `Scene::pose_state`'s answer. Opaque; owns its
/// transforms and does not borrow the scene. Freed with `cadaclysm_pose_free`.
#[repr(C)]
pub struct CadaclysmPose {
    _private: [u8; 0],
}

/// A mesh split into meshlets. Opaque.
#[repr(C)]
pub struct CadaclysmMeshlets {
    _private: [u8; 0],
}

/// One body meshed for a solver. Opaque: owned, and freed with
/// `cadaclysm_fem_mesh_free`. Every pointer any accessor of it writes is borrowed from
/// it and dies with it.
#[repr(C)]
pub struct CadaclysmFemMesh {
    _private: [u8; 0],
}

/// `CadaclysmOpenOptions`. `size` is the whole compatibility contract: the library
/// reads only the fields `size` says are there, so a caller built against an older
/// header is safe against a newer library. This crate therefore fills the struct
/// itself, `size` from its own layout, and never calls
/// `cadaclysm_open_options_init`, which writes the *library's* `sizeof` whatever
/// the caller allocated.
#[repr(C)]
pub struct CadaclysmOpenOptions {
    pub size: usize,
    pub convention: u32,
    pub spec: *const c_void,
    pub file_units: bool,
    pub uvs: u32,
    pub colors: u32,
    pub source_meters_per_unit: f64,
    pub schemas: *const *const c_char,
    pub schema_count: usize,
    pub schema_text: *const u8,
    pub schema_length: usize,
    /// `CadaclysmPick`, a function pointer; null takes the library's default.
    pub pick: *const c_void,
    pub pick_user: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmBounds {
    pub min: [f32; 3],
    pub max: [f32; 3],
}

/// [`CadaclysmBounds`] in `double`: the same box, unnarrowed.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmBounds64 {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

#[repr(C)]
pub struct CadaclysmAttribute {
    pub name: *const c_char,
    pub kind: c_int,
    pub text: *const c_char,
    pub integer: i64,
    pub real: f64,
    pub boolean: bool,
}

#[repr(C)]
pub struct CadaclysmMesh {
    pub positions: *const f32,
    pub normals: *const f32,
    pub uvs: *const f32,
    pub colors: *const f32,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
}

/// [`CadaclysmMesh`] in `double`: the document's own mesh, lent as it is -- see the
/// header. Colours stay `float`. Invalidated by [`crate::Scene::forget_meshes`].
#[repr(C)]
pub struct CadaclysmMesh64 {
    pub positions: *const f64,
    pub normals: *const f64,
    pub uvs: *const f64,
    pub colors: *const f32,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
}

#[repr(C)]
pub struct CadaclysmPolylines {
    pub positions: *const f32,
    pub counts: *const u32,
    pub polyline_count: u32,
    pub vertex_count: u32,
}

/// One RGBA per polyline of [`CadaclysmPolylines`] (same order); alpha `< 0` marks an
/// unstyled edge. `{null, 0}` where nothing is styled.
#[repr(C)]
pub struct CadaclysmEdgeColors {
    pub rgba: *const f32,
    pub count: u32,
}

#[repr(C)]
pub struct CadaclysmBeziers {
    pub points: *const f32,
    pub weights: *const f32,
    pub count: u32,
}

/// [`CadaclysmBeziers`] in `double`: the same segments, unnarrowed.
#[repr(C)]
pub struct CadaclysmBeziers64 {
    pub points: *const f64,
    pub weights: *const f64,
    pub count: u32,
}

#[repr(C)]
pub struct CadaclysmCollision {
    pub size: u32,
    pub shape: u32,
    pub confidence: u32,
    pub axis: u32,
    pub frame: [f64; 16],
    pub half_extent: [f64; 3],
    pub radius: f64,
    pub height: f64,
    pub error: f64,
    pub hull_vertex_count: u32,
    pub hull_index_count: u32,
}

#[repr(C)]
pub struct CadaclysmCollisionHull {
    pub positions: *const f32,
    pub indices: *const u32,
    pub vertex_count: u32,
    pub index_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmFace {
    pub kind: u32,
    pub reversed: u32,
    pub transposed: u32,
    pub reserved: u32,
    pub origin: [f32; 4],
    pub ax: [f32; 4],
    pub ay: [f32; 4],
    pub az: [f32; 4],
    pub domain: [f32; 4],
    pub scalars: [f32; 4],
    pub loop_start: u32,
    pub loop_count: u32,
    pub profile_start: u32,
    pub profile_count: u32,
    pub profile2_start: u32,
    pub profile2_count: u32,
    pub nurbs_start: u32,
    pub nurbs_count: u32,
}

/// `CadaclysmSvgOptions`. `size` is the struct's growth room, as
/// [`CadaclysmOpenOptions`] above -- unlike that one, this crate fills it by calling
/// `cadaclysm_svg_options_init` first (its `size` write is safe here: this struct, not
/// the caller's allocation, is what the library's own `sizeof` describes), then
/// overrides the fields [`crate::SvgOptions`] carries.
#[repr(C)]
pub struct CadaclysmSvgOptions {
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

/// `CadaclysmFemOptions`. `size` is the struct's growth room, as [`CadaclysmOpenOptions`]
/// above -- and like [`CadaclysmSvgOptions`], this crate fills it by calling
/// `cadaclysm_fem_options_init` first (so a field added to the struct later defaults
/// without this crate being touched), then sets `size` to *its own* `sizeof` and overrides
/// `tolerance` and `max_size`. That init writes the **library's** `sizeof` bytes, so this
/// declaration must stay at least as long as the library's -- which is what
/// `cadaclysm-capi/tests/bindings.rs` pins, field by field and width by width.
#[repr(C)]
pub struct CadaclysmFemOptions {
    pub size: usize,
    pub tolerance: f64,
    pub max_size: f64,
}

/// `CadaclysmFemMeshView`: the flat arrays of one FEM mesh and its summary, read once when
/// the handle is made. Every pointer is **borrowed from the handle** -- nothing here is a
/// copy, and nothing is built by the call that hands it over.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmFemMeshView {
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

/// `CadaclysmFemEdge`: one B-rep edge of a FEM mesh, filled by `cadaclysm_fem_mesh_edge`.
/// `id` is the **body's own** edge id; `face_b` and `end_b` are [`CADACLYSM_NONE`] where
/// there is none, and `0` is a real face and a real vertex.
///
/// The one FEM struct with no `size` field, so it cannot grow after a release.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmFemEdge {
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

/// `CadaclysmFemVertex`: one B-rep vertex of a FEM mesh. `point` is meaningless -- and
/// zeroed -- unless `has_position`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmFemVertex {
    pub node: u32,
    pub point: [f64; 3],
    pub has_position: bool,
}

#[repr(C)]
pub struct CadaclysmSurfaces {
    pub faces: *const CadaclysmFace,
    pub face_count: u32,
    pub loops: *const u32,
    pub loop_count: u32,
    pub points: *const f32,
    pub point_count: u32,
    pub profiles: *const f32,
    pub profile_count: u32,
    pub nurbs: *const f32,
    pub nurbs_count: u32,
    pub shared: *const u32,
    pub shared_count: u32,
    pub duplicate: *const u32,
    pub duplicate_count: u32,
}

/// `CadaclysmFreedom`: one of a pair's degrees of freedom -- which motion, about or
/// along which contact-frame axis, and its optional range. The header's `bool` fields
/// are one byte each, so Rust's `bool` (also one byte, `0`/`1`) matches it directly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CadaclysmFreedom {
    pub motion: u32,
    pub axis: u32,
    pub has_lower: bool,
    pub lower: f64,
    pub has_upper: bool,
    pub upper: f64,
}

/// `CadaclysmTaskTime`: every date pair of a task, each `has_*` saying whether its value
/// is given. Seconds since 1970-01-01T00:00; `duration` is in seconds.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CadaclysmTaskTime {
    pub has_schedule_start: bool,
    pub schedule_start: f64,
    pub has_schedule_finish: bool,
    pub schedule_finish: f64,
    pub has_early_start: bool,
    pub early_start: f64,
    pub has_early_finish: bool,
    pub early_finish: f64,
    pub has_late_start: bool,
    pub late_start: f64,
    pub has_late_finish: bool,
    pub late_finish: f64,
    pub has_actual_start: bool,
    pub actual_start: f64,
    pub has_actual_finish: bool,
    pub actual_finish: f64,
    pub has_duration: bool,
    pub duration: f64,
}

/// `CadaclysmElementState`: one element's state on a date, from `cadaclysm_schedule_at`.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CadaclysmElementState {
    pub node: u32,
    pub phase: u32,
    pub progress: f64,
    pub has_variance: bool,
    pub variance: f64,
}

entry_points! {
    Api, ENTRY_POINTS;
    fn cadaclysm_last_error() -> *const c_char;
    fn cadaclysm_version() -> *const c_char;
    fn cadaclysm_license_set(text_or_path: *const c_char) -> bool;
    fn cadaclysm_license_info() -> *const c_char;
    fn cadaclysm_license_notice_count() -> u64;
    fn cadaclysm_build_date() -> *const c_char;
    fn cadaclysm_open(path: *const c_char, options: *const CadaclysmOpenOptions) -> *mut CadaclysmScene;
    fn cadaclysm_open_memory(
        bytes: *const u8,
        length: usize,
        format: *const c_char,
        options: *const CadaclysmOpenOptions
    ) -> *mut CadaclysmScene;
    fn cadaclysm_open_options_init(options: *mut CadaclysmOpenOptions);
    fn cadaclysm_close(scene: *mut CadaclysmScene);
    fn cadaclysm_source_name(scene: *const CadaclysmScene) -> *const c_char;
    fn cadaclysm_node_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_root_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_root(scene: *const CadaclysmScene, index: u32) -> u32;
    fn cadaclysm_schema(scene: *const CadaclysmScene) -> *const c_char;
    fn cadaclysm_schema_read(scene: *const CadaclysmScene) -> *const c_char;
    fn cadaclysm_metres_per_unit(scene: *const CadaclysmScene) -> f64;
    fn cadaclysm_bounds(scene: *const CadaclysmScene) -> CadaclysmBounds;
    fn cadaclysm_bounds64(scene: *const CadaclysmScene) -> CadaclysmBounds64;
    fn cadaclysm_node_parent(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_child_count(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_child(scene: *const CadaclysmScene, node: u32, index: u32) -> u32;
    fn cadaclysm_node_depth(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_name(scene: *const CadaclysmScene, node: u32) -> *const c_char;
    fn cadaclysm_node_kind(scene: *const CadaclysmScene, node: u32) -> *const c_char;
    fn cadaclysm_node_visible(scene: *const CadaclysmScene, node: u32) -> bool;
    fn cadaclysm_node_save_mesh(
        scene: *const CadaclysmScene,
        node: u32,
        path: *const c_char,
        format: *const c_char
    ) -> bool;
    fn cadaclysm_scene_save(scene: *const CadaclysmScene, path: *const c_char, format: *const c_char) -> bool;
    fn cadaclysm_mesh_format_count() -> u32;
    fn cadaclysm_mesh_format(index: u32) -> *const c_char;
    fn cadaclysm_mesh_format_extension(index: u32) -> *const c_char;
    fn cadaclysm_mesh_format_label(index: u32) -> *const c_char;
    fn cadaclysm_format_count() -> u32;
    fn cadaclysm_format_name(index: u32) -> *const c_char;
    fn cadaclysm_format_extensions(index: u32) -> *const c_char;
    fn cadaclysm_query(scene: *const CadaclysmScene, filter: *const c_char, out: *mut u32, capacity: u32) -> u32;
    fn cadaclysm_pick_file(parent: *const c_void) -> *const c_char;
    fn cadaclysm_pick_save(parent: *const c_void, suggested_name: *const c_char) -> *const c_char;
    fn cadaclysm_node_id(scene: *const CadaclysmScene, node: u32) -> *const c_char;
    fn cadaclysm_node_color(scene: *const CadaclysmScene, node: u32, rgba: *mut f32) -> bool;
    fn cadaclysm_node_transform(scene: *const CadaclysmScene, node: u32, out: *mut f64);
    fn cadaclysm_node_attribute_count(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_attribute(scene: *const CadaclysmScene, node: u32, index: u32) -> CadaclysmAttribute;
    fn cadaclysm_placement_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_placement_geometry(scene: *const CadaclysmScene, placement: u32) -> u32;
    fn cadaclysm_placement_select(scene: *const CadaclysmScene, placement: u32) -> u32;
    fn cadaclysm_placement_transform(scene: *const CadaclysmScene, placement: u32, out: *mut f64);
    fn cadaclysm_node_can_mesh(scene: *const CadaclysmScene, node: u32) -> bool;
    fn cadaclysm_node_mesh(scene: *const CadaclysmScene, node: u32) -> CadaclysmMesh;
    fn cadaclysm_node_mesh64(scene: *const CadaclysmScene, node: u32) -> CadaclysmMesh64;
    fn cadaclysm_lod_levels() -> u32;
    fn cadaclysm_node_mesh_lod(scene: *const CadaclysmScene, node: u32, level: u32) -> CadaclysmMesh;
    fn cadaclysm_node_lod_error(scene: *const CadaclysmScene, node: u32, level: u32) -> f32;
    fn cadaclysm_node_collision(scene: *const CadaclysmScene, node: u32, hull_budget: u32, out: *mut CadaclysmCollision) -> bool;
    fn cadaclysm_node_collision_hull(scene: *const CadaclysmScene, node: u32, hull_budget: u32) -> CadaclysmCollisionHull;
    fn cadaclysm_node_bounds_placed(scene: *const CadaclysmScene, node: u32, placement: *const f64) -> CadaclysmBounds;
    fn cadaclysm_node_bounds_placed64(scene: *const CadaclysmScene, node: u32, placement: *const f64) -> CadaclysmBounds64;
    fn cadaclysm_node_is_meshed(scene: *const CadaclysmScene, node: u32) -> bool;
    fn cadaclysm_node_surface_edges(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_surface_edge_beziers(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers;
    fn cadaclysm_node_surface_isocurves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_surface_pick(scene: *const CadaclysmScene, node: u32, from: *const f64, to: *const f64, out_point: *mut f64) -> bool;
    fn cadaclysm_node_surface_proxy_mesh(scene: *const CadaclysmScene, node: u32, cells: u32) -> CadaclysmMesh;
    fn cadaclysm_node_triangle_estimate(scene: *const CadaclysmScene, node: u32) -> i64;
    fn cadaclysm_node_surfaces(scene: *const CadaclysmScene, node: u32) -> CadaclysmSurfaces;
    fn cadaclysm_node_brep(scene: *const CadaclysmScene, node: u32) -> *const CadaclysmBrep;
    fn cadaclysm_brep_release(brep: *const CadaclysmBrep);
    fn cadaclysm_brep_manifold(brep: *const CadaclysmBrep, out: *mut u32) -> bool;
    fn cadaclysm_brep_sew(brep: *const CadaclysmBrep, tolerance: f64, vertex: f64, out: *mut u32, gaps: *mut f64) -> *const CadaclysmBrep;
    fn cadaclysm_brep_layout_id() -> *const c_char;
    fn cadaclysm_surface_matrix(scene: *const CadaclysmScene, out: *mut f32);
    fn cadaclysm_node_bounds(scene: *const CadaclysmScene, node: u32) -> CadaclysmBounds;
    fn cadaclysm_node_bounds64(scene: *const CadaclysmScene, node: u32) -> CadaclysmBounds64;
    fn cadaclysm_node_instance_of(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_select_as(scene: *const CadaclysmScene, node: u32) -> u32;
    fn cadaclysm_node_generator(scene: *const CadaclysmScene, node: u32) -> *const c_char;
    fn cadaclysm_diagnostic_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_diagnostic(scene: *const CadaclysmScene, index: u32) -> *const c_char;
    fn cadaclysm_geometry_diagnostic_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_geometry_diagnostic(scene: *const CadaclysmScene, index: u32) -> *const c_char;
    fn cadaclysm_node_edges(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_edge_colors(scene: *const CadaclysmScene, node: u32) -> CadaclysmEdgeColors;
    fn cadaclysm_node_surface_edge_colors(scene: *const CadaclysmScene, node: u32) -> CadaclysmEdgeColors;
    fn cadaclysm_node_curves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_isocurves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_edge_beziers(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers;
    fn cadaclysm_node_edge_beziers64(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers64;
    // Borrowed into a per-scene slot that the next silhouette call on the scene replaces: see
    // `Node::silhouette_beziers`, which copies out of it under a lock before returning.
    fn cadaclysm_node_silhouette_beziers(scene: *const CadaclysmScene, node: u32, options: *const CadaclysmSvgOptions) -> CadaclysmBeziers64;
    fn cadaclysm_node_curve_beziers(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers;
    fn cadaclysm_node_curve_beziers64(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers64;
    fn cadaclysm_node_isocurve_beziers(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers;
    fn cadaclysm_node_isocurve_beziers64(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers64;
    fn cadaclysm_realize_all(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_realize_meshes(scene: *const CadaclysmScene, skip_surfaced: u32) -> u32;
    fn cadaclysm_realized(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_realize_total(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_cancel(scene: *const CadaclysmScene);
    fn cadaclysm_meshlets_build(positions: *const f32, normals: *const f32, vertex_count: usize, indices: *const u32, index_count: usize, max_triangles: u32, max_vertices: u32, levels: i32) -> *mut CadaclysmMeshlets;
    fn cadaclysm_meshlets_count(handle: *const CadaclysmMeshlets) -> u32;
    fn cadaclysm_meshlets_free(handle: *mut CadaclysmMeshlets);
    fn cadaclysm_meshlet_triangle_count(handle: *const CadaclysmMeshlets, index: u32) -> u32;
    fn cadaclysm_meshlet_vertex_count(handle: *const CadaclysmMeshlets, index: u32) -> u32;
    fn cadaclysm_meshlet_level(handle: *const CadaclysmMeshlets, index: u32) -> u32;
    fn cadaclysm_meshlet_group(handle: *const CadaclysmMeshlets, index: u32) -> u32;
    fn cadaclysm_meshlet_error(handle: *const CadaclysmMeshlets, index: u32) -> f32;
    fn cadaclysm_meshlet_child_count(handle: *const CadaclysmMeshlets, index: u32) -> u32;
    fn cadaclysm_meshlet_positions(handle: *const CadaclysmMeshlets, index: u32, out: *mut f32);
    fn cadaclysm_meshlet_normals(handle: *const CadaclysmMeshlets, index: u32, out: *mut f32);
    fn cadaclysm_meshlet_indices(handle: *const CadaclysmMeshlets, index: u32, out: *mut u32);
    fn cadaclysm_meshlet_children(handle: *const CadaclysmMeshlets, index: u32, out: *mut u32);
    fn cadaclysm_forget_meshes(scene: *mut CadaclysmScene);
    fn cadaclysm_svg_options_init(options: *mut CadaclysmSvgOptions);
    fn cadaclysm_parse_colour(text: *const c_char, out: *mut f64) -> bool;
    fn cadaclysm_scene_svg_text(scene: *const CadaclysmScene, options: *const CadaclysmSvgOptions) -> *const c_char;
    fn cadaclysm_scene_svg(scene: *const CadaclysmScene, path: *const c_char, options: *const CadaclysmSvgOptions) -> bool;
    fn cadaclysm_node_svg_text(scene: *const CadaclysmScene, node: u32, options: *const CadaclysmSvgOptions) -> *const c_char;
    fn cadaclysm_node_svg(scene: *const CadaclysmScene, node: u32, path: *const c_char, options: *const CadaclysmSvgOptions) -> bool;
    fn cadaclysm_link_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_link_name(scene: *const CadaclysmScene, link: u32) -> *const c_char;
    fn cadaclysm_link_node_count(scene: *const CadaclysmScene, link: u32) -> u32;
    fn cadaclysm_link_node(scene: *const CadaclysmScene, link: u32, index: u32) -> u32;
    fn cadaclysm_joint_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_joint_name(scene: *const CadaclysmScene, joint: u32) -> *const c_char;
    fn cadaclysm_joint_start(scene: *const CadaclysmScene, joint: u32) -> u32;
    fn cadaclysm_joint_end(scene: *const CadaclysmScene, joint: u32) -> u32;
    fn cadaclysm_joint_pair_kind(scene: *const CadaclysmScene, joint: u32) -> i32;
    fn cadaclysm_joint_pair_type(scene: *const CadaclysmScene, joint: u32) -> *const c_char;
    fn cadaclysm_joint_pair_kind_name(scene: *const CadaclysmScene, joint: u32) -> *const c_char;
    fn cadaclysm_joint_pair_parameters(scene: *const CadaclysmScene, joint: u32, out: *mut f64, capacity: usize) -> usize;
    fn cadaclysm_joint_pair_pitch(scene: *const CadaclysmScene, joint: u32) -> f64;
    fn cadaclysm_joint_pair_frames(scene: *const CadaclysmScene, joint: u32, out_start: *mut f64, out_end: *mut f64) -> bool;
    fn cadaclysm_joint_freedom_count(scene: *const CadaclysmScene, joint: u32) -> u32;
    fn cadaclysm_joint_freedom(scene: *const CadaclysmScene, joint: u32, index: u32, out: *mut CadaclysmFreedom) -> bool;
    fn cadaclysm_state_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_state_name(scene: *const CadaclysmScene, state: u32) -> *const c_char;
    fn cadaclysm_state_value_count(scene: *const CadaclysmScene, state: u32) -> u32;
    fn cadaclysm_state_value(
        scene: *const CadaclysmScene,
        state: u32,
        row: u32,
        joint: *mut u32,
        values: *mut f64,
        capacity: u32
    ) -> u32;
    fn cadaclysm_sequence_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_sequence_name(scene: *const CadaclysmScene, sequence: u32) -> *const c_char;
    fn cadaclysm_sequence_closed(scene: *const CadaclysmScene, sequence: u32) -> bool;
    fn cadaclysm_sequence_seconds_per_unit(scene: *const CadaclysmScene, sequence: u32) -> f64;
    fn cadaclysm_sequence_segment_count(scene: *const CadaclysmScene, sequence: u32) -> u32;
    fn cadaclysm_sequence_segment(
        scene: *const CadaclysmScene,
        sequence: u32,
        segment: u32,
        state: *mut u32,
        t: *mut f64,
        interpolation: *mut u32
    ) -> bool;
    fn cadaclysm_schedule_count(scene: *const CadaclysmScene) -> u32;
    fn cadaclysm_schedule_name(scene: *const CadaclysmScene, s: u32) -> *const c_char;
    fn cadaclysm_schedule_identification(scene: *const CadaclysmScene, s: u32) -> *const c_char;
    fn cadaclysm_schedule_kind(scene: *const CadaclysmScene, s: u32) -> u32;
    fn cadaclysm_schedule_kind_name(scene: *const CadaclysmScene, s: u32) -> *const c_char;
    fn cadaclysm_schedule_start(scene: *const CadaclysmScene, s: u32, out: *mut f64) -> bool;
    fn cadaclysm_schedule_finish(scene: *const CadaclysmScene, s: u32, out: *mut f64) -> bool;
    fn cadaclysm_task_count(scene: *const CadaclysmScene, s: u32) -> u32;
    fn cadaclysm_task_name(scene: *const CadaclysmScene, s: u32, t: u32) -> *const c_char;
    fn cadaclysm_task_identification(scene: *const CadaclysmScene, s: u32, t: u32) -> *const c_char;
    fn cadaclysm_task_kind(scene: *const CadaclysmScene, s: u32, t: u32) -> u32;
    fn cadaclysm_task_kind_name(scene: *const CadaclysmScene, s: u32, t: u32) -> *const c_char;
    fn cadaclysm_task_status(scene: *const CadaclysmScene, s: u32, t: u32) -> *const c_char;
    fn cadaclysm_task_milestone(scene: *const CadaclysmScene, s: u32, t: u32) -> bool;
    fn cadaclysm_task_parent(scene: *const CadaclysmScene, s: u32, t: u32, out: *mut u32) -> bool;
    fn cadaclysm_task_time(scene: *const CadaclysmScene, s: u32, t: u32, out: *mut CadaclysmTaskTime) -> bool;
    fn cadaclysm_task_node_count(scene: *const CadaclysmScene, s: u32, t: u32) -> u32;
    fn cadaclysm_task_nodes(scene: *const CadaclysmScene, s: u32, t: u32, out: *mut u32, capacity: u32) -> u32;
    fn cadaclysm_task_link_count(scene: *const CadaclysmScene, s: u32) -> u32;
    fn cadaclysm_task_link(
        scene: *const CadaclysmScene,
        s: u32,
        l: u32,
        from: *mut u32,
        to: *mut u32,
        kind: *mut u32,
        lag: *mut f64,
        has_lag: *mut bool
    ) -> bool;
    fn cadaclysm_task_link_kind_name(scene: *const CadaclysmScene, s: u32, l: u32) -> *const c_char;
    fn cadaclysm_schedule_at(
        scene: *const CadaclysmScene,
        s: u32,
        date: f64,
        dates: u32,
        out: *mut CadaclysmElementState,
        capacity: u32
    ) -> i64;
    fn cadaclysm_fem_options_init(options: *mut CadaclysmFemOptions);
    fn cadaclysm_node_fem_mesh(
        scene: *const CadaclysmScene,
        node: u32,
        placement: *const f64,
        options: *const CadaclysmFemOptions
    ) -> *mut CadaclysmFemMesh;
    fn cadaclysm_fem_mesh_view(m: *const CadaclysmFemMesh, out: *mut CadaclysmFemMeshView) -> bool;
    fn cadaclysm_fem_mesh_edge(m: *const CadaclysmFemMesh, i: u32, out: *mut CadaclysmFemEdge) -> bool;
    fn cadaclysm_fem_mesh_vertex(m: *const CadaclysmFemMesh, i: u32, out: *mut CadaclysmFemVertex) -> bool;
    fn cadaclysm_fem_mesh_open_edge(m: *const CadaclysmFemMesh, i: u32, a: *mut u32, b: *mut u32, brep_edge: *mut u32) -> bool;
    fn cadaclysm_fem_mesh_folded_edge(m: *const CadaclysmFemMesh, i: u32, a: *mut u32, b: *mut u32, brep_edge: *mut u32) -> bool;
    fn cadaclysm_fem_mesh_crossing_count(m: *const CadaclysmFemMesh) -> u32;
    fn cadaclysm_fem_mesh_crossing(m: *const CadaclysmFemMesh, i: u32, a: *mut u32, b: *mut u32) -> bool;
    fn cadaclysm_fem_mesh_msh_text(m: *const CadaclysmFemMesh) -> *const c_char;
    fn cadaclysm_fem_mesh_save_msh(m: *const CadaclysmFemMesh, path: *const c_char) -> bool;
    fn cadaclysm_fem_mesh_free(m: *mut CadaclysmFemMesh);
    fn cadaclysm_pose(
        scene: *const CadaclysmScene,
        joints: *const u32,
        counts: *const u32,
        values: *const f64,
        row_count: u32,
        ground: u32
    ) -> *mut CadaclysmPose;
    fn cadaclysm_pose_state(scene: *const CadaclysmScene, state: u32, ground: u32) -> *mut CadaclysmPose;
    fn cadaclysm_pose_sequence(scene: *const CadaclysmScene, sequence: u32, t: f64, ground: u32) -> *mut CadaclysmPose;
    fn cadaclysm_pose_free(pose: *mut CadaclysmPose);
    fn cadaclysm_pose_ground(pose: *const CadaclysmPose) -> u32;
    fn cadaclysm_pose_node_count(pose: *const CadaclysmPose) -> u32;
    fn cadaclysm_pose_node_transform(pose: *const CadaclysmPose, node: u32, out: *mut f64);
    fn cadaclysm_pose_unsolved_count(pose: *const CadaclysmPose) -> u32;
    fn cadaclysm_pose_unsolved(pose: *const CadaclysmPose, index: u32) -> u32;
    fn cadaclysm_pose_diagnostic_count(pose: *const CadaclysmPose) -> u32;
    fn cadaclysm_pose_diagnostic(pose: *const CadaclysmPose, index: u32) -> *const c_char;
    fn cadaclysm_pose_out_of_range_count(pose: *const CadaclysmPose) -> u32;
    fn cadaclysm_pose_out_of_range(
        pose: *const CadaclysmPose,
        index: u32,
        joint: *mut u32,
        freedom: *mut u32,
        value: *mut f64
    ) -> bool;
    fn cadaclysm_kinematics_base(scene: *const CadaclysmScene) -> u32;
}

// ---- loading --------------------------------------------------------------------

static LIBRARY: Loader<Api> = Loader::new("cadaclysm_capi", "CADACLYSM_LIBRARY", Api::bind);

/// The library's file name on this platform.
pub fn library_name() -> String {
    LIBRARY.file_name()
}

/// Where the library would be loaded from, without loading it -- or, where nothing
/// was found, every place that was looked in.
///
/// `CADACLYSM_LIBRARY` first (the library itself or its directory); then beside the
/// running executable; then a `lib/` directory in any ancestor of the executable or
/// of the working directory (the SDK's layout); then a `target/release` or
/// `target/debug` in any of those ancestors (the repository's layout).
pub fn find_library() -> Result<PathBuf, String> {
    LIBRARY.find()
}

/// Load the library at `path` (or where [`find_library`] finds it) and bind every
/// entry point, once per process.
pub fn load(path: Option<&Path>) -> Result<&'static Api, String> {
    LIBRARY.load(path)
}

/// The path the library was loaded from, or `None` before anything loaded it.
pub fn loaded_path() -> Option<&'static Path> {
    LIBRARY.loaded_path()
}

/// The bound function table, loading the library on first use.
pub fn api() -> Result<&'static Api, String> {
    load(None)
}
