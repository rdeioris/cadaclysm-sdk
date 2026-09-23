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

/// A mesh split into meshlets. Opaque.
#[repr(C)]
pub struct CadaclysmMeshlets {
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
    fn cadaclysm_node_surface_isocurves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_surface_pick(scene: *const CadaclysmScene, node: u32, from: *const f64, to: *const f64, out_point: *mut f64) -> bool;
    fn cadaclysm_node_surface_proxy_mesh(scene: *const CadaclysmScene, node: u32, cells: u32) -> CadaclysmMesh;
    fn cadaclysm_node_triangle_estimate(scene: *const CadaclysmScene, node: u32) -> i64;
    fn cadaclysm_node_surfaces(scene: *const CadaclysmScene, node: u32) -> CadaclysmSurfaces;
    fn cadaclysm_node_brep(scene: *const CadaclysmScene, node: u32) -> *const CadaclysmBrep;
    fn cadaclysm_brep_release(brep: *const CadaclysmBrep);
    fn cadaclysm_brep_manifold(brep: *const CadaclysmBrep, out: *mut u32) -> bool;
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
    fn cadaclysm_node_curves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_isocurves(scene: *const CadaclysmScene, node: u32) -> CadaclysmPolylines;
    fn cadaclysm_node_edge_beziers(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers;
    fn cadaclysm_node_edge_beziers64(scene: *const CadaclysmScene, node: u32) -> CadaclysmBeziers64;
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
    fn cadaclysm_scene_svg_text(scene: *const CadaclysmScene, options: *const CadaclysmSvgOptions) -> *const c_char;
    fn cadaclysm_scene_svg(scene: *const CadaclysmScene, path: *const c_char, options: *const CadaclysmSvgOptions) -> bool;
    fn cadaclysm_node_svg_text(scene: *const CadaclysmScene, node: u32, options: *const CadaclysmSvgOptions) -> *const c_char;
    fn cadaclysm_node_svg(scene: *const CadaclysmScene, node: u32, path: *const c_char, options: *const CadaclysmSvgOptions) -> bool;
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
