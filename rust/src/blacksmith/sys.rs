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

#[repr(C)]
pub struct CadaclysmBlacksmithPolylines {
    pub points: *const f32,
    /// `polyline_count + 1` entries; the last equals `point_count`.
    pub offsets: *const u32,
    pub point_count: u32,
    pub polyline_count: u32,
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

/// `CadaclysmBlacksmithProgress`: `(phase, done, total, user)`, or null for none.
pub type CadaclysmBlacksmithProgress = Option<unsafe extern "C" fn(*const c_char, usize, usize, *mut c_void)>;

type Solid = CadaclysmBlacksmithSolid;
type Profile = CadaclysmBlacksmithProfile;
type Path2 = CadaclysmBlacksmithPath;
type SweepPath = CadaclysmBlacksmithSweepPath;
type Progress = CadaclysmBlacksmithProgress;
type Hits = CadaclysmBlacksmithHits;
type Intersection = CadaclysmBlacksmithIntersection;
type ProfileList = CadaclysmBlacksmithProfileList;

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
    fn cadaclysm_blacksmith_rotate(solid: *const Solid, axis: *const f64, radians: f64) -> *mut Solid;
    fn cadaclysm_blacksmith_mirror(solid: *const Solid, plane: *const f64) -> *mut Solid;
    fn cadaclysm_blacksmith_coloured(solid: *const Solid, face: u32, r: f64, g: f64, b: f64) -> *mut Solid;

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
    fn cadaclysm_blacksmith_mesh(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithMesh;
    fn cadaclysm_blacksmith_mesh64(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithMesh64;
    fn cadaclysm_blacksmith_mesh_face_triangles(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithFaceTriangles;
    fn cadaclysm_blacksmith_edge_polylines(solid: *const Solid, tolerance: f64) -> CadaclysmBlacksmithPolylines;
    fn cadaclysm_blacksmith_bounds(solid: *const Solid, tolerance: f64, min: *mut f64, max: *mut f64) -> bool;
    fn cadaclysm_blacksmith_bounds64(solid: *const Solid, tolerance: f64, min: *mut f64, max: *mut f64) -> bool;
    fn cadaclysm_blacksmith_step(solids: *const *const Solid, count: usize, schema: *const c_char, unit: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_sat_text(solids: *const *const Solid, count: usize, unit: u32) -> *mut c_char;
    fn cadaclysm_blacksmith_sat(solids: *const *const Solid, count: usize, path: *const c_char, unit: u32) -> bool;
    fn cadaclysm_blacksmith_brep_text(solids: *const *const Solid, count: usize) -> *mut c_char;
    fn cadaclysm_blacksmith_brep(solids: *const *const Solid, count: usize, path: *const c_char) -> bool;
    fn cadaclysm_blacksmith_svg_options_init(options: *mut CadaclysmBlacksmithSvgOptions);
    fn cadaclysm_blacksmith_svg_text(solids: *const *const Solid, count: usize, options: *const CadaclysmBlacksmithSvgOptions) -> *mut c_char;
    fn cadaclysm_blacksmith_svg(solids: *const *const Solid, count: usize, path: *const c_char, options: *const CadaclysmBlacksmithSvgOptions) -> bool;
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
