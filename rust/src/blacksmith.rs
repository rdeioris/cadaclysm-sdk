//! The exact modelling kernel, `cadaclysm_blacksmith`, as Rust types.
//!
//! ```no_run
//! use cadaclysm_sdk::blacksmith::{Axis, Profile, Selector, Workplane, DEFAULT_TOLERANCE, FILLET_TOLERANCE};
//!
//! fn main() -> cadaclysm_sdk::Result<()> {
//!     let outline = Profile::rect(80.0, 40.0)?.with_hole(&Profile::circle(4.0)?)?;
//!     let plate = Workplane::xy().extrude(&outline, 6.0)?.solid()?;
//!     let pin = Workplane::from_solid(&plate)
//!         .faces(&Selector::Max(Axis::Z))?
//!         .on_face()?
//!         .cylinder(5.0, 10.0)?
//!         .solid()?;
//!     let part = plate.join(&pin, DEFAULT_TOLERANCE)?;
//!     let corners: Vec<u32> = part
//!         .edges()?
//!         .iter()
//!         .filter(|e| e.direction().is_some_and(|d| d[2].abs() > 0.99))
//!         .map(|e| e.index)
//!         .collect();
//!     let mut part = part.fillet(&corners, 1.0, FILLET_TOLERANCE)?;
//!     part.step("plate.stp", None, Default::default())?;
//!     let mesh = part.mesh(0.05)?;
//!     println!("{} triangles", mesh.triangle_count());
//!     Ok(())
//! }
//! ```
//!
//! A second shared library, loaded on first use like the reader's: from
//! `CADACLYSM_BLACKSMITH_LIBRARY`, else beside the executable, else a `lib/` or
//! `target/release` in an ancestor directory -- see [`sys::find_library`]. It keeps
//! its own license state, so [`license`] is its own call.
//!
//! # Solids are immutable, and not for two threads at once
//!
//! Every operation returns a new [`Solid`] and leaves its inputs as they were; dropping
//! one frees it. A solid caches its tessellation, which is why [`Solid`] is `Send`
//! but not `Sync`: the kernel says a handle is not for two threads at once, and here
//! the compiler holds that.
//!
//! [`Solid::mesh`] and [`Solid::edge_polylines`] hand back slices into that cache,
//! uncopied. Meshing again at another tolerance replaces the cache, so both take
//! `&mut self`: while a mesh is borrowed, nothing can re-mesh the solid under it.
//! [`crate::Mesh::copy`] gives arrays of the program's own.
//!
//! ```compile_fail,E0499
//! # use cadaclysm_sdk::blacksmith::Solid;
//! let mut solid = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
//! let fine = solid.mesh(0.05).unwrap();
//! let coarse = solid.mesh(0.5).unwrap(); // error: the first mesh still borrows the cache
//! let _ = fine.indices.len();
//! ```
//!
//! ```compile_fail,E0277
//! fn shared<T: Sync>() {}
//! shared::<cadaclysm_sdk::blacksmith::Solid>(); // error: a solid is not for two threads at once
//! ```
//!
//! # Solids from files
//!
//! [`Solid::open`] reads a STEP, ACIS, Rhino, OCCT `.brep`, IGES or IFC file's body
//! through the reader library, and [`Solid::from_node`] takes one node of a
//! [`crate::Scene`] already open: the reader's B-rep is handed to the kernel by
//! pointer and shared, never copied, so the two libraries must come from the same
//! release (the call checks).
//!
//! `join`/`cut`/`common` take a tolerance, [`DEFAULT_TOLERANCE`] being what the
//! kernel's own boolean tests run at; `fillet`, `chamfer` and `shell` want the
//! tighter [`FILLET_TOLERANCE`].

use std::ffi::{c_char, CString};
use std::fmt;
use std::path::{Path as FsPath, PathBuf};
use std::ptr::{self, NonNull};

use crate::{borrowed, groups, text, Error, Manifold, Mesh, Node, OpenOptions, Result, Scene};

pub mod sys;

use sys::Api;

/// What the kernel returns for "none" -- `CADACLYSM_BLACKSMITH_NONE`.
pub const NONE: u32 = sys::CADACLYSM_BLACKSMITH_NONE;

/// The tolerance booleans, bounds and meshes default to elsewhere: what the kernel's
/// own boolean tests run at. A tighter one is as correct, only slower.
pub const DEFAULT_TOLERANCE: f64 = 0.05;

/// The tolerance `fillet`, `chamfer` and `shell` default to elsewhere.
pub const FILLET_TOLERANCE: f64 = 1e-6;

/// What the kernel refused, in its own words. The crate's one error type.
pub type BuildError = Error;

fn api() -> Result<&'static Api> {
    sys::api().map_err(Error::new)
}

/// The kernel's own reason for the last failure on this thread, or `what`.
fn fail(api: &Api, what: &str) -> Error {
    let reason = unsafe { text((api.cadaclysm_blacksmith_last_error)()) };
    Error::new(if reason.is_empty() { what.to_string() } else { reason })
}

/// Whether the kernel left a reason for the last call on this thread.
fn failed(api: &Api) -> bool {
    !unsafe { (api.cadaclysm_blacksmith_last_error)() }.is_null()
        && !unsafe { text((api.cadaclysm_blacksmith_last_error)()) }.is_empty()
}

fn c_text(what: &str, value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::new(format!("{what} contains a NUL byte")))
}

// ---- the library ------------------------------------------------------------------

/// Load the kernel library from `path` before anything else asks for it.
pub fn load(path: impl AsRef<FsPath>) -> Result<()> {
    sys::load(Some(path.as_ref())).map(|_| ()).map_err(Error::new)
}

/// Where the kernel library is: the one loaded, or the one the next call would load.
pub fn library_path() -> Result<PathBuf> {
    match sys::loaded_path() {
        Some(path) => Ok(path.to_path_buf()),
        None => sys::find_library().map_err(Error::new),
    }
}

/// The version of the kernel library actually loaded.
pub fn version() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_blacksmith_version)()) })
}

/// When the loaded kernel library was built, `YYYY-MM-DD`.
pub fn build_date() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_blacksmith_build_date)()) })
}

/// Load a license into the kernel: the certificate text, or the path of a file
/// holding it. The kernel keeps its own license state, apart from the reader's.
pub fn license(text_or_path: impl AsRef<std::ffi::OsStr>) -> Result<()> {
    let api = api()?;
    let given = c_text("license", &text_or_path.as_ref().to_string_lossy())?;
    if unsafe { (api.cadaclysm_blacksmith_license_set)(given.as_ptr()) } {
        Ok(())
    } else {
        Err(fail(api, "license refused"))
    }
}

/// One line about the license the kernel is running under, or `"unlicensed"`.
pub fn license_info() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_blacksmith_license_info)()) })
}

/// How many unlicensed notices the kernel has printed to stderr in this process.
pub fn license_notice_count() -> Result<u64> {
    let api = api()?;
    Ok(unsafe { (api.cadaclysm_blacksmith_license_notice_count)() })
}

/// How the kernel lays a brep out in memory. [`Solid::from_node`] works only where
/// this equals the reader's ([`crate::Brep::layout_id`]): the two from one release.
pub fn brep_layout_id() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_blacksmith_brep_layout_id)()) })
}

/// `ap203.exp`: in `CADACLYSM_SCHEMAS` if set, else beside the executable, else in a
/// `schemas/` directory in an ancestor of the executable or the working directory.
///
/// **Not needed to write STEP**: the kernel writes against its built-in AP203 when no
/// schema is given. Kept for the other wrappers' parity.
pub fn default_schema() -> Result<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(dir) = std::env::var_os("CADACLYSM_SCHEMAS").filter(|v| !v.is_empty()) {
        candidates.push(PathBuf::from(dir).join("ap203.exp"));
    }
    let exe_dir = std::env::current_exe().ok().and_then(|exe| exe.parent().map(FsPath::to_path_buf));
    if let Some(dir) = &exe_dir {
        candidates.push(dir.join("ap203.exp"));
    }
    for start in exe_dir.into_iter().chain(std::env::current_dir().ok()) {
        candidates.extend(start.ancestors().map(|dir| dir.join("schemas").join("ap203.exp")));
    }
    candidates.into_iter().find(|c| c.is_file()).ok_or_else(|| {
        Error::new(
            "ap203.exp not found (none is needed to write STEP: leave the schema out for the built-in AP203, \
             or pass a schema name, a .exp path or EXPRESS text)",
        )
    })
}

// ---- frames -----------------------------------------------------------------------

/// How far from square a frame's axes may be (the cosine between two of them).
const SQUARE: f64 = 1e-6;

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn unit(v: [f64; 3], what: &str) -> Result<[f64; 3]> {
    let n = dot(v, v).sqrt();
    if !(n > 1e-12 && n.is_finite()) {
        return Err(Error::new(format!("{what} has no direction")));
    }
    Ok(v.map(|c| c / n))
}

/// An origin and three unit axes, square to each other and right-handed (z = x × y):
/// the plane a profile is drawn on (its x/y) and the direction it is built along (its
/// z). Every constructor checks, so a `Frame` in hand is always a valid one.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    v: [f64; 12],
}

impl Frame {
    /// A frame from its origin and axes, normalised; fails where the axes are not
    /// square or not right-handed.
    pub fn new(origin: [f64; 3], x: [f64; 3], y: [f64; 3], z: [f64; 3]) -> Result<Frame> {
        if !origin.iter().all(|c| c.is_finite()) {
            return Err(Error::new("Frame: origin must be three finite numbers"));
        }
        let (x, y, z) = (unit(x, "Frame: x")?, unit(y, "Frame: y")?, unit(z, "Frame: z")?);
        if dot(x, y).abs().max(dot(y, z).abs()).max(dot(z, x).abs()) > SQUARE {
            return Err(Error::new("Frame: the axes are not square to each other"));
        }
        if dot(cross(x, y), z) < 0.0 {
            return Err(Error::new("Frame: the axes are left-handed (z must be x × y)"));
        }
        let mut v = [0.0; 12];
        for (i, c) in origin.iter().chain(&x).chain(&y).chain(&z).enumerate() {
            v[i] = c + 0.0; // no -0.0 to print or compare
        }
        Ok(Frame { v })
    }

    /// Twelve numbers -- origin, x, y, z -- checked as [`Frame::new`] checks.
    pub fn of(raw: [f64; 12]) -> Result<Frame> {
        let at = |i: usize| [raw[i], raw[i + 1], raw[i + 2]];
        Frame::new(at(0), at(3), at(6), at(9))
    }

    /// The world XY plane through `origin`: z up.
    pub fn xy(origin: [f64; 3]) -> Frame {
        Frame::XY.translate(origin[0], origin[1], origin[2])
    }

    /// The world XZ plane through `origin`: x along X, y along Z, so z is -Y.
    pub fn xz(origin: [f64; 3]) -> Frame {
        Frame::XZ.translate(origin[0], origin[1], origin[2])
    }

    /// The world YZ plane through `origin`: x along Y, y along Z, so z is +X.
    pub fn yz(origin: [f64; 3]) -> Frame {
        Frame::YZ.translate(origin[0], origin[1], origin[2])
    }

    const XY: Frame = Frame { v: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0] };
    const XZ: Frame = Frame { v: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, -1.0, 0.0] };
    const YZ: Frame = Frame { v: [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0] };

    /// The plane through `origin` square to `normal` (the frame's z). Its x axis is
    /// `x` laid onto that plane; with `None`, world X laid onto it, or world Y when the
    /// normal is within about 25° of X -- the axes [`Solid::face_frame`] gives a face
    /// facing `normal`. A normal along +Z, -Y or +X gives exactly `xy`, `xz` or `yz`.
    pub fn at(origin: [f64; 3], normal: [f64; 3], x: Option<[f64; 3]>) -> Result<Frame> {
        let z = unit(normal, "Frame.at: normal")?;
        let hint = unit(x.unwrap_or(if z[0].abs() <= 0.9 { [1.0, 0.0, 0.0] } else { [0.0, 1.0, 0.0] }), "Frame.at: x")?;
        let d = dot(hint, z);
        if d.abs() > 1.0 - SQUARE {
            return Err(Error::new("Frame.at: x lies along the normal"));
        }
        let x = unit([hint[0] - d * z[0], hint[1] - d * z[1], hint[2] - d * z[2]], "Frame.at: x")?;
        Frame::new(origin, x, cross(z, x), z)
    }

    pub fn origin(&self) -> [f64; 3] {
        [self.v[0], self.v[1], self.v[2]]
    }

    pub fn x(&self) -> [f64; 3] {
        [self.v[3], self.v[4], self.v[5]]
    }

    pub fn y(&self) -> [f64; 3] {
        [self.v[6], self.v[7], self.v[8]]
    }

    pub fn z(&self) -> [f64; 3] {
        [self.v[9], self.v[10], self.v[11]]
    }

    /// The twelve numbers every call taking a frame reads.
    pub fn raw(&self) -> [f64; 12] {
        self.v
    }

    /// This frame moved by (`dx`, `dy`, `dz`) in world coordinates.
    pub fn translate(&self, dx: f64, dy: f64, dz: f64) -> Frame {
        let mut v = self.v;
        v[0] += dx;
        v[1] += dy;
        v[2] += dz;
        Frame { v: v.map(|c| c + 0.0) }
    }

    /// This frame moved `distance` along its own z.
    pub fn offset(&self, distance: f64) -> Frame {
        let z = self.z();
        self.translate(distance * z[0], distance * z[1], distance * z[2])
    }
}

impl fmt::Display for Frame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Frame(origin={:?}, x={:?}, y={:?}, z={:?})", self.origin(), self.x(), self.y(), self.z())
    }
}

/// A point and a direction, `[[px, py, pz], [dx, dy, dz]]`: what `revolve`, `coil`
/// and `rotate` turn about.
pub type AxisLine = [[f64; 3]; 2];

fn axis_raw(axis: &AxisLine) -> [f64; 6] {
    [axis[0][0], axis[0][1], axis[0][2], axis[1][0], axis[1][1], axis[1][2]]
}

// ---- profiles ---------------------------------------------------------------------

/// A closed outline with holes (or an open chain, from [`Path::end_open`]), in its own
/// x/y. Immutable: every method returns a new one.
pub struct Profile {
    handle: NonNull<sys::CadaclysmBlacksmithProfile>,
    api: &'static Api,
}

// Immutable once built, and nothing in it is cached.
unsafe impl Send for Profile {}
unsafe impl Sync for Profile {}

impl Drop for Profile {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_profile_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Profile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Profile({:p})", self.handle)
    }
}

impl Profile {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithProfile, what: &str) -> Result<Profile> {
        NonNull::new(raw).map(|handle| Profile { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithProfile {
        self.handle.as_ptr()
    }

    pub fn rect(w: f64, h: f64) -> Result<Profile> {
        let api = api()?;
        Profile::wrap(api, unsafe { (api.cadaclysm_blacksmith_profile_rect)(w, h) }, "profile_rect")
    }

    pub fn circle(r: f64) -> Result<Profile> {
        let api = api()?;
        Profile::wrap(api, unsafe { (api.cadaclysm_blacksmith_profile_circle)(r) }, "profile_circle")
    }

    /// A slot: two half-circles of radius `r` whose centres are `length` apart along
    /// x, about `centre`.
    pub fn slot(centre: [f64; 2], length: f64, r: f64) -> Result<Profile> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_slot)(centre[0], centre[1], length, r) };
        Profile::wrap(api, raw, "profile_slot")
    }

    pub fn polygon(points: &[[f64; 2]]) -> Result<Profile> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_polygon)(points.as_ptr().cast(), points.len()) };
        Profile::wrap(api, raw, "profile_polygon")
    }

    /// A regular polygon of `sides` sides (at least 3) on the circle of `radius` about
    /// `centre`, its first corner at `angle` radians from the sketch's x axis.
    pub fn regular_polygon(centre: [f64; 2], radius: f64, sides: u32, angle: f64) -> Result<Profile> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_regular_polygon)(centre[0], centre[1], radius, sides, angle) };
        Profile::wrap(api, raw, "profile_regular_polygon")
    }

    /// A spline of `degree` through the control polygon `points` (`weights` one per
    /// point, or `None`). Open, it starts on the first point and ends on the last; closed,
    /// it is periodic -- a closed profile. The degree is lowered to fit the points.
    pub fn spline(points: &[[f64; 2]], degree: u32, weights: Option<&[f64]>, closed: bool) -> Result<Profile> {
        let api = api()?;
        if let Some(w) = weights.filter(|w| w.len() != points.len()) {
            return Err(Error::new(format!("profile_spline: {} weights for {} points", w.len(), points.len())));
        }
        let raw = unsafe {
            (api.cadaclysm_blacksmith_profile_spline)(
                points.as_ptr().cast(),
                points.len(),
                degree,
                weights.map_or(ptr::null(), <[f64]>::as_ptr),
                closed,
            )
        };
        Profile::wrap(api, raw, "profile_spline")
    }

    /// An outline drawn a segment at a time from `start`.
    pub fn path(start: [f64; 2]) -> Result<Path> {
        Path::begin(start)
    }

    /// Open profiles joined end to end into one: in any order and either way round,
    /// each next one the first of the rest with an end within `tolerance` of either end
    /// of the chain so far. Closed where the chain's two ends meet.
    pub fn chain(pieces: &[&Profile], tolerance: f64) -> Result<Profile> {
        let api = api()?;
        let handles: Vec<_> = pieces.iter().map(|p| p.raw()).collect();
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_chain)(handles.as_ptr(), handles.len(), tolerance) };
        Profile::wrap(api, raw, "profile_chain")
    }

    /// Closed loops, in any order, as one profile: the loop enclosing the most area is
    /// the boundary and every other a hole in it -- a sketch's rectangle and the circles
    /// drawn inside it.
    pub fn from_loops(loops: &[&Profile]) -> Result<Profile> {
        let api = api()?;
        let handles: Vec<_> = loops.iter().map(|p| p.raw()).collect();
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_from_loops)(handles.as_ptr(), handles.len()) };
        Profile::wrap(api, raw, "profile_from_loops")
    }

    /// This profile closed: a straight segment back to the start where it stops short,
    /// the last segment landed on the start exactly where it comes back within 1e-9.
    pub fn close_loop(&self) -> Result<Profile> {
        Profile::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_profile_close_loop)(self.raw()) }, "profile_close_loop")
    }

    pub fn with_hole(&self, hole: &Profile) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_with_hole)(self.raw(), hole.raw()) };
        Profile::wrap(self.api, raw, "profile_with_hole")
    }

    pub fn translate(&self, dx: f64, dy: f64) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_translate_profile)(self.raw(), dx, dy) };
        Profile::wrap(self.api, raw, "translate_profile")
    }

    /// This profile with its corners rounded by `radius` where two straight segments
    /// meet. `corners: None` rounds every such corner, the holes' too; a list picks
    /// corners of the boundary alone (corner `k` is where segment `k` ends). `open`
    /// reads it as an open chain, whose two ends stay square.
    pub fn round(&self, radius: f64, corners: Option<&[u32]>, open: bool) -> Result<Profile> {
        let (picked, count) = corners.map_or((ptr::null(), 0), |c| (c.as_ptr(), c.len()));
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_round)(self.raw(), radius, picked, count, open) };
        Profile::wrap(self.api, raw, "profile_round")
    }
}

/// An outline drawn a segment at a time. Each step consumes the builder and hands it
/// back, so a chain reads `Path::begin([0.0, 0.0])?.line_to(10.0, 0.0)?...end()?`; a
/// builder dropped unfinished is freed.
pub struct Path {
    handle: NonNull<sys::CadaclysmBlacksmithPath>,
    api: &'static Api,
}

unsafe impl Send for Path {}

impl Drop for Path {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_path_free)(self.handle.as_ptr()) }
    }
}

impl Path {
    pub fn begin(start: [f64; 2]) -> Result<Path> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_path_begin)(start[0], start[1]) };
        NonNull::new(raw).map(|handle| Path { handle, api }).ok_or_else(|| fail(api, "path_begin"))
    }

    fn step(self, ok: bool, what: &str) -> Result<Path> {
        if ok {
            Ok(self)
        } else {
            Err(fail(self.api, what))
        }
    }

    pub fn line_to(self, x: f64, y: f64) -> Result<Path> {
        let ok = unsafe { (self.api.cadaclysm_blacksmith_path_line_to)(self.handle.as_ptr(), x, y) };
        self.step(ok, "path_line_to")
    }

    /// An arc to (`x`, `y`) about `centre`, counter-clockwise unless `ccw` is false.
    pub fn arc_to(self, x: f64, y: f64, centre: [f64; 2], ccw: bool) -> Result<Path> {
        let ok = unsafe { (self.api.cadaclysm_blacksmith_path_arc_to)(self.handle.as_ptr(), x, y, centre[0], centre[1], ccw) };
        self.step(ok, "path_arc_to")
    }

    pub fn bezier_to(self, c1: [f64; 2], c2: [f64; 2], to: [f64; 2]) -> Result<Path> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_path_bezier_to)(self.handle.as_ptr(), c1[0], c1[1], c2[0], c2[1], to[0], to[1])
        };
        self.step(ok, "path_bezier_to")
    }

    /// `control`: every control point after the current one, the endpoint last;
    /// `weights`: one per control point *including* the current one, or `None`;
    /// `knots`: the full repeated knot vector.
    pub fn nurbs_to(self, control: &[[f64; 2]], knots: &[f64], degree: u32, weights: Option<&[f64]>) -> Result<Path> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_path_nurbs_to)(
                self.handle.as_ptr(),
                control.as_ptr().cast(),
                control.len(),
                weights.map_or(ptr::null(), <[f64]>::as_ptr),
                knots.as_ptr(),
                knots.len(),
                degree,
            )
        };
        self.step(ok, "path_nurbs_to")
    }

    /// Close the outline into a [`Profile`].
    pub fn end(self) -> Result<Profile> {
        self.finish(false)
    }

    /// The path as it stands, without closing it: an open chain for `extrude_open`,
    /// `sweep_open`, `loft_open` or [`SweepPath::along`].
    pub fn end_open(self) -> Result<Profile> {
        self.finish(true)
    }

    fn finish(self, open: bool) -> Result<Profile> {
        // `end` consumes the builder whether or not it succeeds, so it must not be
        // freed again by `Drop`.
        let (api, handle) = (self.api, self.handle.as_ptr());
        std::mem::forget(self);
        let raw = unsafe {
            if open {
                (api.cadaclysm_blacksmith_path_end_open)(handle)
            } else {
                (api.cadaclysm_blacksmith_path_end)(handle)
            }
        };
        Profile::wrap(api, raw, if open { "path_end_open" } else { "path_end" })
    }
}

/// A 3D path a profile is carried along -- lines and arcs -- for [`Solid::sweep`],
/// [`Solid::sweep_open`] and [`Solid::pipe`], which only borrow it: sweep it as often
/// as needed. Each step consumes the builder and hands it back.
pub struct SweepPath {
    handle: NonNull<sys::CadaclysmBlacksmithSweepPath>,
    api: &'static Api,
}

unsafe impl Send for SweepPath {}

impl Drop for SweepPath {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_sweep_path_free)(self.handle.as_ptr()) }
    }
}

impl SweepPath {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSweepPath, what: &str) -> Result<SweepPath> {
        NonNull::new(raw).map(|handle| SweepPath { handle, api }).ok_or_else(|| fail(api, what))
    }

    /// A path starting at `point`.
    pub fn at(point: [f64; 3]) -> Result<SweepPath> {
        let api = api()?;
        SweepPath::wrap(api, unsafe { (api.cadaclysm_blacksmith_sweep_path_begin)(point[0], point[1], point[2]) }, "sweep_path_begin")
    }

    /// The path the 2D chain `curve` draws on `frame`: lines and arcs as they are, a
    /// Bezier or spline fitted with tangent biarcs to within `tolerance`, so the path is
    /// tangent throughout. `open: false` closes it back to its start.
    pub fn along(curve: &Profile, frame: &Frame, tolerance: f64, open: bool) -> Result<SweepPath> {
        let api = curve.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_sweep_path_along)(curve.raw(), frame.v.as_ptr(), tolerance, open) };
        SweepPath::wrap(api, raw, "sweep_path_along")
    }

    fn step(self, ok: bool, what: &str) -> Result<SweepPath> {
        if ok {
            Ok(self)
        } else {
            Err(fail(self.api, what))
        }
    }

    pub fn line_to(self, point: [f64; 3]) -> Result<SweepPath> {
        let ok = unsafe { (self.api.cadaclysm_blacksmith_sweep_path_line_to)(self.handle.as_ptr(), point[0], point[1], point[2]) };
        self.step(ok, "sweep_path_line_to")
    }

    /// Turn `angle` radians (in `(0, 2π]`) about the axis through `centre` along
    /// `axis` (need not be unit).
    pub fn arc(self, centre: [f64; 3], axis: [f64; 3], angle: f64) -> Result<SweepPath> {
        let [cx, cy, cz] = centre;
        let [ax, ay, az] = axis;
        let ok = unsafe { (self.api.cadaclysm_blacksmith_sweep_path_arc)(self.handle.as_ptr(), cx, cy, cz, ax, ay, az, angle) };
        self.step(ok, "sweep_path_arc")
    }

    /// Free it now rather than at the end of scope.
    pub fn close(self) {}

    fn raw(&self) -> *const sys::CadaclysmBlacksmithSweepPath {
        self.handle.as_ptr()
    }
}

/// A plane a sweep starts or ends on, read as a height over the sketch plane at each
/// point: `at + grad · p`. Flat for `extrude`'s own caps; sloped for a mitre. A bare
/// number converts to a flat one.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slant {
    pub at: f64,
    pub grad: [f64; 2],
}

impl Slant {
    pub fn flat(at: f64) -> Slant {
        Slant { at, grad: [0.0, 0.0] }
    }

    /// The plane through `point` square to `normal`, read as heights over `frame`.
    /// Fails where the plane holds the sweep direction itself.
    pub fn of_plane(frame: &Frame, point: [f64; 3], normal: [f64; 3]) -> Result<Slant> {
        let api = api()?;
        let mut out = [0.0; 3];
        if unsafe { (api.cadaclysm_blacksmith_slant_of_plane)(frame.v.as_ptr(), point.as_ptr(), normal.as_ptr(), out.as_mut_ptr()) } {
            Ok(Slant { at: out[0], grad: [out[1], out[2]] })
        } else {
            Err(fail(api, "slant_of_plane"))
        }
    }

    fn raw(&self) -> [f64; 3] {
        [self.at, self.grad[0], self.grad[1]]
    }
}

impl From<f64> for Slant {
    fn from(at: f64) -> Slant {
        Slant::flat(at)
    }
}

// ---- selecting, edges -------------------------------------------------------------

/// A world axis, for [`Selector::Max`] and [`Selector::Min`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Axis {
    X = 0,
    Y = 1,
    Z = 2,
}

/// Which face: furthest along an axis, furthest against it, by outward normal, or by
/// index.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Selector {
    Max(Axis),
    Min(Axis),
    Normal([f64; 3]),
    Index(u32),
}

impl Selector {
    fn raw(&self) -> (u32, Option<[f64; 3]>, u32) {
        match *self {
            Selector::Max(axis) => (0, None, axis as u32),
            Selector::Min(axis) => (1, None, axis as u32),
            Selector::Normal(v) => (2, Some(v), 0),
            Selector::Index(i) => (3, None, i),
        }
    }
}

/// One edge of a solid, as plain data: its index (what [`Solid::fillet`] takes), its
/// curve kind, the faces meeting on it, and its segments' ends.
#[derive(Clone, Debug, PartialEq)]
pub struct Edge {
    pub index: u32,
    pub kind: String,
    pub faces: Vec<u32>,
    pub segments: Vec<[[f64; 3]; 2]>,
}

impl Edge {
    pub fn is_line(&self) -> bool {
        self.kind == "line"
    }

    /// Unit direction of a line edge (from its first segment), else `None`.
    pub fn direction(&self) -> Option<[f64; 3]> {
        let [a, b] = *self.segments.first().filter(|_| self.is_line())?;
        unit([b[0] - a[0], b[1] - a[1], b[2] - a[2]], "edge").ok()
    }
}

/// Which side of the tool [`Solid::trim`] keeps.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Keep {
    /// What lies outside the tool: a hole punched through the sheet.
    #[default]
    Outside,
    /// What lies within it: the sheet cut to the tool's outline.
    Inside,
}

/// The length unit a STEP file is written in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Unit {
    Metre = 0,
    #[default]
    Millimetre = 1,
    Inch = 2,
}

/// `(r, g, b)` in 0..1 from `"#rgb"` or `"#rrggbb"` (the `#` optional).
pub fn rgb(hex: &str) -> Result<[f64; 3]> {
    let h = hex.trim();
    let h = h.strip_prefix('#').unwrap_or(h);
    let doubled: String = if h.len() == 3 { h.chars().flat_map(|c| [c, c]).collect() } else { h.to_string() };
    if doubled.len() == 6 && doubled.chars().all(|c| c.is_ascii_hexdigit()) {
        let at = |i: usize| u8::from_str_radix(&doubled[i..i + 2], 16).map(|v| f64::from(v) / 255.0).unwrap_or(0.0);
        return Ok([at(0), at(2), at(4)]);
    }
    Err(Error::new(format!("coloured: a colour is \"#rgb\" or \"#rrggbb\", not {hex:?}")))
}

// ---- solids -----------------------------------------------------------------------

/// An exact B-rep solid (or open sheet). Immutable: every operation returns a new one.
/// Dropping it frees it. `Send`, not `Sync` -- see the module docs.
pub struct Solid {
    handle: NonNull<sys::CadaclysmBlacksmithSolid>,
    api: &'static Api,
}

// A solid owns its brep reference and its caches outright, so it may move to another
// thread. It is not `Sync`: its tessellation cache is a `RefCell` on the kernel's side.
unsafe impl Send for Solid {}

impl Drop for Solid {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_solid_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Solid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Solid({:p})", self.handle)
    }
}

/// The null progress callback and user pointer every combining call passes.
const NO_PROGRESS: sys::CadaclysmBlacksmithProgress = None;

impl Solid {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSolid, what: &str) -> Result<Solid> {
        NonNull::new(raw).map(|handle| Solid { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithSolid {
        self.handle.as_ptr()
    }

    fn next(&self, raw: *mut sys::CadaclysmBlacksmithSolid, what: &str) -> Result<Solid> {
        Solid::wrap(self.api, raw, what)
    }

    /// Free it now rather than at the end of scope.
    pub fn close(self) {}

    // -- building

    pub fn cuboid(x: f64, y: f64, z: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_cuboid)(x, y, z) }, "cuboid")
    }

    pub fn cylinder(r: f64, h: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_cylinder)(r, h) }, "cylinder")
    }

    pub fn cone(r: f64, h: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_cone)(r, h) }, "cone")
    }

    pub fn sphere(r: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_sphere)(r) }, "sphere")
    }

    pub fn torus(major: f64, minor: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_torus)(major, minor) }, "torus")
    }

    pub fn wedge(x: f64, y: f64, z: f64, top_x: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_wedge)(x, y, z, top_x) }, "wedge")
    }

    pub fn extrude(profile: &Profile, frame: &Frame, height: f64) -> Result<Solid> {
        let api = profile.api;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_extrude)(profile.raw(), frame.v.as_ptr(), height) }, "extrude")
    }

    /// `extrude` without the caps: an open sheet of walls.
    pub fn extrude_open(profile: &Profile, frame: &Frame, height: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_extrude_open)(profile.raw(), frame.v.as_ptr(), height) };
        Solid::wrap(api, raw, "extrude_open")
    }

    /// `extrude` with a draft: the walls lean out by `taper` radians as they rise (in,
    /// when negative), every wall exact.
    pub fn extrude_tapered(profile: &Profile, frame: &Frame, height: f64, taper: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_extrude_tapered)(profile.raw(), frame.v.as_ptr(), height, taper) };
        Solid::wrap(api, raw, "extrude_tapered")
    }

    pub fn extrude_open_tapered(profile: &Profile, frame: &Frame, height: f64, taper: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_extrude_open_tapered)(profile.raw(), frame.v.as_ptr(), height, taper) };
        Solid::wrap(api, raw, "extrude_open_tapered")
    }

    /// `extrude` between two planes instead of two heights -- each a [`Slant`], or a
    /// bare number for a flat one. With both flat this *is* `extrude`.
    pub fn extrude_between(profile: &Profile, frame: &Frame, bottom: impl Into<Slant>, top: impl Into<Slant>) -> Result<Solid> {
        let (bottom, top) = (bottom.into().raw(), top.into().raw());
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_extrude_between)(profile.raw(), frame.v.as_ptr(), bottom.as_ptr(), top.as_ptr()) };
        Solid::wrap(api, raw, "extrude_between")
    }

    /// `extrude_between` without the caps.
    pub fn extrude_open_between(profile: &Profile, frame: &Frame, bottom: impl Into<Slant>, top: impl Into<Slant>) -> Result<Solid> {
        let (bottom, top) = (bottom.into().raw(), top.into().raw());
        let api = profile.api;
        let raw =
            unsafe { (api.cadaclysm_blacksmith_extrude_open_between)(profile.raw(), frame.v.as_ptr(), bottom.as_ptr(), top.as_ptr()) };
        Solid::wrap(api, raw, "extrude_open_between")
    }

    /// The solid between `a` on `frame_a` and `b` on `frame_b`: ruled walls between
    /// matching sides (the same number of sides, no holes), capped by the two.
    pub fn loft(a: &Profile, frame_a: &Frame, b: &Profile, frame_b: &Frame) -> Result<Solid> {
        let api = a.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_loft)(a.raw(), frame_a.v.as_ptr(), b.raw(), frame_b.v.as_ptr()) };
        Solid::wrap(api, raw, "loft")
    }

    /// `loft` without the caps.
    pub fn loft_open(a: &Profile, frame_a: &Frame, b: &Profile, frame_b: &Frame) -> Result<Solid> {
        let api = a.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_loft_open)(a.raw(), frame_a.v.as_ptr(), b.raw(), frame_b.v.as_ptr()) };
        Solid::wrap(api, raw, "loft_open")
    }

    /// `profile`, read as (distance from the axis, height along it), swung `angle`
    /// radians about `axis`.
    pub fn revolve(profile: &Profile, axis: &AxisLine, angle: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_revolve)(profile.raw(), axis_raw(axis).as_ptr(), angle) };
        Solid::wrap(api, raw, "revolve")
    }

    pub fn revolve_open(profile: &Profile, axis: &AxisLine, angle: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_revolve_open)(profile.raw(), axis_raw(axis).as_ptr(), angle) };
        Solid::wrap(api, raw, "revolve_open")
    }

    /// `profile`, drawn on `frame`, swung `angle` radians about the axis through the
    /// sketch points `a` and `b` -- the profile and its axis drawn together.
    pub fn revolve_in_plane(profile: &Profile, frame: &Frame, a: [f64; 2], b: [f64; 2], angle: f64) -> Result<Solid> {
        let api = profile.api;
        let axis = [a[0], a[1], b[0], b[1]];
        let raw = unsafe { (api.cadaclysm_blacksmith_revolve_in_plane)(profile.raw(), frame.v.as_ptr(), axis.as_ptr(), angle) };
        Solid::wrap(api, raw, "revolve_in_plane")
    }

    pub fn revolve_open_in_plane(profile: &Profile, frame: &Frame, a: [f64; 2], b: [f64; 2], angle: f64) -> Result<Solid> {
        let api = profile.api;
        let axis = [a[0], a[1], b[0], b[1]];
        let raw = unsafe { (api.cadaclysm_blacksmith_revolve_open_in_plane)(profile.raw(), frame.v.as_ptr(), axis.as_ptr(), angle) };
        Solid::wrap(api, raw, "revolve_open_in_plane")
    }

    /// `profile` coiled about `axis`, read as `revolve` reads it, turned `turns` times
    /// while climbing `pitch` each turn: a spring, a thread.
    pub fn coil(profile: &Profile, axis: &AxisLine, pitch: f64, turns: f64) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_coil)(profile.raw(), axis_raw(axis).as_ptr(), pitch, turns) };
        Solid::wrap(api, raw, "coil")
    }

    /// `profile`, drawn on `frame`, carried along `path` into a closed solid: a
    /// straight piece is an extrusion, a circular one a revolution, nothing approximated.
    pub fn sweep(profile: &Profile, frame: &Frame, path: &SweepPath) -> Result<Solid> {
        let api = profile.api;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_sweep)(profile.raw(), frame.v.as_ptr(), path.raw()) }, "sweep")
    }

    /// `sweep` for a curve: one wall per segment per piece, no caps.
    pub fn sweep_open(profile: &Profile, frame: &Frame, path: &SweepPath) -> Result<Solid> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_sweep_open)(profile.raw(), frame.v.as_ptr(), path.raw()) };
        Solid::wrap(api, raw, "sweep_open")
    }

    /// A circle of `radius` swept along `path`: a rod, or with a positive `thickness`
    /// a tube whose walls are that thick.
    pub fn pipe(path: &SweepPath, radius: f64, thickness: f64) -> Result<Solid> {
        let api = path.api;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_pipe)(path.raw(), radius, thickness) }, "pipe")
    }

    /// The flat sheet `profile` bounds on `frame`: one planar face, each hole a hole
    /// through it -- raise it with `extrude_faces`, cut it with `trim` or `split_sheet`.
    pub fn face(profile: &Profile, frame: &Frame) -> Result<Solid> {
        let api = profile.api;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_face)(profile.raw(), frame.v.as_ptr()) }, "face")
    }

    // -- from files

    /// The body `node` draws, as a solid -- **sharing the reader's brep, not copying
    /// it**. The scene can be dropped before the solid: the brep lives on.
    ///
    /// `placed` puts it where the node's transform does (a moved copy unless that is the
    /// identity), which needs a scene opened in its native convention; `false` keeps the
    /// node's own frame. The reader and kernel libraries must be from one release.
    pub fn from_node(node: &Node<'_>, placed: bool) -> Result<Solid> {
        let what = format!("from_node: node {} ({})", node.index(), node.label());
        let solid = from_brep(node, &what)?.ok_or_else(|| Error::new(no_brep(&what)))?;
        if !placed {
            return Ok(solid);
        }
        let transform = node.transform();
        if node.scene().convention() != 0 && !is_identity(&transform) {
            return Err(Error::new(
                "from_node: placed needs the scene opened in its native convention -- the brep is in the file's own \
                 axes and the node's transform is not; open natively, or pass placed = false",
            ));
        }
        solid.placed(&transform, "from_node")
    }

    /// The body a CAD file holds, as a solid, read where it draws in the file's own
    /// units and axes: STEP, ACIS, Rhino, OCCT `.brep`, IGES or IFC. A file of several
    /// bodies needs `body` (0-based, in drawing order) -- or [`Solid::open_all`].
    ///
    /// What such a solid can do is what its geometry allows: fillet and chamfer want
    /// line and circle edges, and every verb meshes its operands first, so its cost
    /// grows with the body's face count.
    pub fn open(path: impl AsRef<FsPath>, body: Option<usize>) -> Result<Solid> {
        let path = path.as_ref();
        let mut solids = Solid::open_all(path)?;
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        match body {
            None if solids.len() == 1 => Ok(solids.remove(0)),
            None => Err(Error::new(format!(
                "open: {name} holds {} bodies: pass a body (0 to {}), or use Solid::open_all",
                solids.len(),
                solids.len() - 1
            ))),
            Some(body) if body < solids.len() => Ok(solids.swap_remove(body)),
            Some(body) => Err(Error::new(format!("open: {name} has no body {body}: it holds {}", solids.len()))),
        }
    }

    /// Every body a CAD file draws, as solids placed where it draws them: one per
    /// placement, so a part placed twice is two solids.
    pub fn open_all(path: impl AsRef<FsPath>) -> Result<Vec<Solid>> {
        let path = path.as_ref();
        let scene = crate::open(path).map_err(|e| Error::new(format!("open: {e}")))?;
        let mut solids = Vec::new();
        for placement in scene.placements() {
            let node = placement.geometry();
            let what = format!("open: {}", node.label());
            if let Some(solid) = from_brep(&node, &what)? {
                solids.push(solid.placed(&placement.transform(), &what)?);
            }
        }
        if solids.is_empty() {
            let extension = path.extension().unwrap_or_default().to_string_lossy();
            return Err(Error::new(format!(
                "open: the .{extension} file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, IGES or IFC \
                 body can be a solid, not a mesh, a curve or a CSG body"
            )));
        }
        Ok(solids)
    }

    /// `self` moved by a row-major placement: itself at the identity, a moved copy for
    /// a rigid move (a mirror included), refused for a scale or shear, which a brep
    /// cannot follow exactly.
    fn placed(self, m: &[[f64; 4]; 4], what: &str) -> Result<Solid> {
        if is_identity(m) {
            return Ok(self);
        }
        let column = |j: usize| [m[0][j], m[1][j], m[2][j]];
        for i in 0..3 {
            for j in 0..3 {
                let expected = if i == j { 1.0 } else { 0.0 };
                if (dot(column(i), column(j)) - expected).abs() > 1e-9 {
                    return Err(Error::new(format!("{what}: the placement scales or shears, which a brep cannot follow")));
                }
            }
        }
        let [x, y, z] = [column(0), column(1), column(2)];
        let frame = [m[0][3], m[1][3], m[2][3], x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2]];
        // Raw rather than a `Frame`: a mirror's axes are left-handed, which a
        // placement may be and a `Frame` may not.
        self.next(unsafe { (self.api.cadaclysm_blacksmith_place)(self.raw(), frame.as_ptr()) }, "place")
    }

    // -- one solid to another

    /// Face `face` alone, as an open sheet: what extruding a solid's face starts from.
    pub fn face_sheet(&self, face: u32) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_face_sheet)(self.raw(), face) }, "face_sheet")
    }

    /// This solid without the faces at `faces`: the rest keep their order, so an index
    /// into the result is this one's with the dropped ones closed up.
    pub fn drop_faces(&self, faces: &[u32]) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_drop_faces)(self.raw(), faces.as_ptr(), faces.len()) }, "drop_faces")
    }

    /// A sheet raised `height` along its faces' normals into a solid.
    pub fn extrude_faces(&self, height: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_extrude_faces)(self.raw(), height) }, "extrude_faces")
    }

    /// This solid moved so that its own XY frame lands on `frame`.
    pub fn place(&self, frame: &Frame) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_place)(self.raw(), frame.v.as_ptr()) }, "place")
    }

    pub fn translate(&self, dx: f64, dy: f64, dz: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_translate)(self.raw(), dx, dy, dz) }, "translate")
    }

    pub fn rotate(&self, axis: &AxisLine, radians: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_rotate)(self.raw(), axis_raw(axis).as_ptr(), radians) }, "rotate")
    }

    /// This solid mirrored in the plane through `plane`'s origin, square to its z.
    pub fn mirror(&self, plane: &Frame) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_mirror)(self.raw(), plane.v.as_ptr()) }, "mirror")
    }

    // -- combining

    /// This solid and `other` as one. [`Solid::merge_flush`] then merges the flush
    /// faces the join leaves, as Fusion does.
    pub fn join(&self, other: &Solid, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_join)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "join")
    }

    /// This solid with `other` removed.
    pub fn cut(&self, other: &Solid, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_cut)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "cut")
    }

    /// What this solid and `other` share.
    pub fn common(&self, other: &Solid, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_common)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "common")
    }

    /// `self` (a sheet or a solid) cut along the closed `tool`'s boundary and the
    /// pieces on one side thrown away; the kept pieces come in `self`'s face order.
    pub fn trim(&self, tool: &Solid, keep: Keep, tolerance: f64) -> Result<Solid> {
        let inside = keep == Keep::Inside;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_trim)(self.raw(), tool.raw(), inside, tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "trim")
    }

    /// `self` cut along `tool`'s boundary, nothing removed: each face's pieces outside
    /// `tool` then its pieces inside, in `self`'s face order. Keep or discard pieces
    /// with [`Solid::drop_faces`].
    pub fn split_sheet(&self, tool: &Solid, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_split_sheet)(self.raw(), tool.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "split_sheet")
    }

    /// Round `edges` (indices from [`Solid::edges`]) to `radius`.
    pub fn fillet(&self, edges: &[u32], radius: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_fillet)(self.raw(), edges.as_ptr(), edges.len(), radius, tolerance, NO_PROGRESS, ptr::null_mut())
        };
        self.next(raw, "fillet")
    }

    /// `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
    pub fn chamfer(&self, edges: &[u32], distance: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_chamfer)(self.raw(), edges.as_ptr(), edges.len(), distance, tolerance) };
        self.next(raw, "chamfer")
    }

    /// Face `face` pushed out by `distance` along its outward normal (in, negative) and
    /// the flush faces merged, as Fusion and Rhino extrude a face. A face on a cylinder,
    /// a cone, a sphere or a torus moves out along its normal instead, the surface a step
    /// out -- a boss fatter, a bore or a countersink narrower, a dome fuller -- with the
    /// flat faces beside it carried along; any other curved face is refused.
    pub fn push_pull(&self, face: u32, distance: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_push_pull)(self.raw(), face, distance, tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "push_pull")
    }

    /// This solid split by `tool` into bodies: a closed tool gives the parts outside
    /// it, then the parts inside; a flat sheet splits by its whole plane.
    pub fn split(&self, tool: &Solid, tolerance: f64) -> Result<Vec<Solid>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_split)(self.raw(), tool.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "split")?.lumps()
    }

    /// This solid split by the plane through `plane`'s origin, square to its z: the
    /// bodies in front of it first, then those behind.
    pub fn split_by_plane(&self, plane: &Frame, tolerance: f64) -> Result<Vec<Solid>> {
        let raw =
            unsafe { (self.api.cadaclysm_blacksmith_split_by_plane)(self.raw(), plane.v.as_ptr(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "split_by_plane")?.lumps()
    }

    /// This solid's connected bodies, each a solid of its own, in the order of their
    /// first faces.
    pub fn lumps(&self) -> Result<Vec<Solid>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_lump_count)(self.raw()) };
        if count == 0 {
            return Err(fail(self.api, "lump_count"));
        }
        (0..count).map(|i| self.next(unsafe { (self.api.cadaclysm_blacksmith_lump)(self.raw(), i) }, "lump")).collect()
    }

    /// This solid with its flush faces merged: the seams a `join` leaves where two
    /// parts are flush.
    pub fn merge_flush(&self) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_merge_flush)(self.raw()) }, "merge_flush")
    }

    /// This solid hollowed to walls `thickness` thick, the faces at `open` removed so
    /// the hollow is reachable.
    pub fn shell(&self, thickness: f64, open: &[u32], tolerance: f64) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_shell)(self.raw(), thickness, open.as_ptr(), open.len(), tolerance, NO_PROGRESS, ptr::null_mut())
        };
        self.next(raw, "shell")
    }

    // -- colour

    /// This solid coloured `(r, g, b)` in 0..1 (see [`rgb`] for hex) -- or, with `face`,
    /// just that face, whose colour then wins over the solid's. What is made from a
    /// coloured solid inherits its colours.
    pub fn coloured(&self, colour: [f64; 3], face: Option<u32>) -> Result<Solid> {
        let face = self.face_or_none(face, "coloured")?;
        let [r, g, b] = colour;
        self.next(unsafe { (self.api.cadaclysm_blacksmith_coloured)(self.raw(), face, r, g, b) }, "coloured")
    }

    /// The solid's colour, or `None`.
    pub fn colour(&self) -> Result<Option<[f64; 3]>> {
        self.colour_of(NONE)
    }

    /// `face`'s colour as drawn -- its own, else the solid's -- or `None`.
    pub fn face_colour(&self, face: u32) -> Result<Option<[f64; 3]>> {
        let face = self.face_or_none(Some(face), "colour")?;
        self.colour_of(face)
    }

    fn face_or_none(&self, face: Option<u32>, what: &str) -> Result<u32> {
        match face {
            None => Ok(NONE),
            // NONE itself would read as the whole solid.
            Some(NONE) => Err(Error::new(format!("{what}: face {NONE} is not one of the solid's"))),
            Some(face) => Ok(face),
        }
    }

    fn colour_of(&self, face: u32) -> Result<Option<[f64; 3]>> {
        let mut out = [0.0; 3];
        if unsafe { (self.api.cadaclysm_blacksmith_colour)(self.raw(), face, out.as_mut_ptr()) } {
            return Ok(Some(out));
        }
        if failed(self.api) {
            return Err(fail(self.api, "colour"));
        }
        Ok(None)
    }

    // -- asking

    /// How many faces it has.
    pub fn faces(&self) -> Result<u32> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_face_count)(self.raw()) };
        if count == 0 && failed(self.api) {
            return Err(fail(self.api, "face_count"));
        }
        Ok(count)
    }

    /// What surface `face` lies on: `"plane"`, `"cylinder"`, `"cone"`, `"sphere"`, ...
    pub fn face_kind(&self, face: u32) -> Result<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_face_kind)(self.raw(), face) };
        if raw.is_null() {
            return Err(fail(self.api, "face_kind"));
        }
        Ok(unsafe { text(raw) })
    }

    /// The face a selector picks.
    pub fn select_face(&self, selector: &Selector) -> Result<u32> {
        let (kind, v, index) = selector.raw();
        let v_ptr = v.as_ref().map_or(ptr::null(), |v| v.as_ptr());
        let face = unsafe { (self.api.cadaclysm_blacksmith_select_face)(self.raw(), kind, v_ptr, index) };
        if face == NONE {
            return Err(fail(self.api, "select_face"));
        }
        Ok(face)
    }

    /// The workplane on `face`: its centre, world X laid onto it and its outward
    /// normal, as [`Frame::at`] lays them.
    pub fn face_frame(&self, face: u32) -> Result<Frame> {
        let mut out = [0.0; 12];
        if !unsafe { (self.api.cadaclysm_blacksmith_face_frame)(self.raw(), face, out.as_mut_ptr()) } {
            return Err(fail(self.api, "face_frame"));
        }
        Frame::of(out)
    }

    /// `bounds_at(DEFAULT_TOLERANCE)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        self.bounds_at(DEFAULT_TOLERANCE)
    }

    /// The axis-aligned bounds `(min, max)` over the positions of its tessellation at
    /// `tolerance` -- the same cache `mesh` fills, so a second call is free.
    ///
    /// `&self`, although it may re-mesh: a mesh borrowed from this solid holds it
    /// `&mut`, so no borrowed slice can be alive while this runs.
    pub fn bounds_at(&self, tolerance: f64) -> Result<([f64; 3], [f64; 3])> {
        let (mut lo, mut hi) = ([0.0; 3], [0.0; 3]);
        if !unsafe { (self.api.cadaclysm_blacksmith_bounds)(self.raw(), tolerance, lo.as_mut_ptr(), hi.as_mut_ptr()) } {
            return Err(fail(self.api, "bounds"));
        }
        Ok((lo, hi))
    }

    /// How many edges of the mesh at `tolerance` are bound by anything other than
    /// exactly two triangles -- zero for a closed solid.
    pub fn leaked_edges(&self, tolerance: f64) -> Result<u32> {
        let n = unsafe { (self.api.cadaclysm_blacksmith_leaked_edges)(self.raw(), tolerance) };
        if n == NONE {
            return Err(fail(self.api, "leaked_edges"));
        }
        Ok(n)
    }

    /// How many edges of the mesh at `tolerance` have directed triangle uses that do
    /// not cancel -- zero for a closed, consistently oriented solid.
    pub fn unpaired_edges(&self, tolerance: f64) -> Result<u32> {
        let n = unsafe { (self.api.cadaclysm_blacksmith_unpaired_edges)(self.raw(), tolerance) };
        if n == NONE {
            return Err(fail(self.api, "unpaired_edges"));
        }
        Ok(n)
    }

    /// `leaked_edges(tolerance) == 0`.
    pub fn is_watertight(&self, tolerance: f64) -> Result<bool> {
        Ok(self.leaked_edges(tolerance)? == 0)
    }

    /// Whether the faces make a manifold, and whether it is closed, read off the
    /// topology rather than a mesh.
    pub fn manifold(&self) -> Result<Manifold> {
        let mut out = [0u32; 8];
        if !unsafe { (self.api.cadaclysm_blacksmith_manifold)(self.raw(), out.as_mut_ptr()) } {
            return Err(fail(self.api, "manifold"));
        }
        Ok(Manifold::from_row(out))
    }

    /// The edges a fillet indexes, copied out.
    pub fn edges(&self) -> Result<Vec<Edge>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_edge_count)(self.raw()) };
        if count == 0 && failed(self.api) {
            return Err(fail(self.api, "edge_count"));
        }
        let mut edges = Vec::with_capacity(count as usize);
        for index in 0..count {
            let mut raw = sys::CadaclysmBlacksmithEdge {
                kind: ptr::null(),
                faces: ptr::null(),
                face_count: 0,
                segments: ptr::null(),
                segment_count: 0,
            };
            if !unsafe { (self.api.cadaclysm_blacksmith_edge)(self.raw(), index, &mut raw) } {
                return Err(fail(self.api, "edge"));
            }
            // SAFETY: the edge table is cached on the solid and never replaced, and
            // everything is copied out before this borrow of `self` ends.
            let (faces, flat) = unsafe {
                (borrowed(raw.faces, raw.face_count as usize), borrowed(raw.segments, 6 * raw.segment_count as usize))
            };
            let segments = flat.chunks_exact(6).map(|s| [[s[0], s[1], s[2]], [s[3], s[4], s[5]]]).collect();
            edges.push(Edge { index, kind: unsafe { text(raw.kind) }, faces: faces.to_vec(), segments });
        }
        Ok(edges)
    }

    // -- out

    /// Its triangles at `tolerance`, as slices into the solid's own cache: positions,
    /// normals, three indices a triangle. `&mut self` because meshing at another
    /// tolerance replaces that cache -- while this mesh is borrowed, nothing can.
    pub fn mesh(&mut self, tolerance: f64) -> Result<Mesh<'_>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_mesh)(self.raw(), tolerance) };
        if raw.positions.is_null() {
            return Err(fail(self.api, "mesh"));
        }
        let n = raw.vertex_count as usize;
        // SAFETY: the cache lives until the solid is freed or re-meshed, and the `&mut`
        // borrow this mesh carries rules out both.
        unsafe {
            Ok(Mesh {
                positions: groups::<3>(raw.positions, n).unwrap_or(&[]),
                normals: groups::<3>(raw.normals, n),
                uvs: None,
                colors: None,
                indices: borrowed(raw.indices, raw.index_count as usize),
            })
        }
    }

    /// The feature edges at `tolerance`, one slice of points per polyline, borrowed
    /// from the cache as [`Solid::mesh`]'s triangles are.
    pub fn edge_polylines(&mut self, tolerance: f64) -> Result<Vec<&[[f32; 3]]>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_edge_polylines)(self.raw(), tolerance) };
        if raw.offsets.is_null() {
            return Err(fail(self.api, "edge_polylines"));
        }
        // SAFETY: as `mesh`.
        let (points, offsets) = unsafe {
            (
                groups::<3>(raw.points, raw.point_count as usize).unwrap_or(&[]),
                borrowed(raw.offsets, raw.polyline_count as usize + 1),
            )
        };
        Ok(offsets
            .windows(2)
            .map(|w| points.get(w[0] as usize..w[1] as usize).unwrap_or(&[]))
            .collect())
    }

    /// This solid as STEP text: AP203 unless `schema` names another -- see
    /// [`write_step_text`].
    pub fn step_text(&self, schema: Option<&str>, unit: Unit) -> Result<String> {
        write_step_text(&[self], schema, unit)
    }

    /// This solid written to a STEP file at `path`.
    pub fn step(&self, path: impl AsRef<FsPath>, schema: Option<&str>, unit: Unit) -> Result<()> {
        write_step(path, &[self], schema, unit)
    }

    /// This solid as a reader [`Scene`], through STEP text: the door to the tree walk
    /// and everything the reader draws. `schema` as [`Solid::step_text`] takes it; the
    /// reader is given it only when it names a file.
    pub fn to_scene(&self, schema: Option<&str>) -> Result<Scene> {
        let text = self.step_text(schema, Unit::Millimetre)?;
        let mut options = OpenOptions::new();
        if let Some(file) = schema.and_then(schema_file) {
            options = options.schema(file);
        }
        options.open_memory(text.as_bytes(), "stp")
    }
}

fn no_brep(what: &str) -> String {
    format!(
        "{what} has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC), not a mesh, a \
         curve or a CSG body"
    )
}

/// The node's brep as a solid, shared -- the reader's reference handed across, the
/// solid holding one of its own -- or `None` where the node has none.
fn from_brep(node: &Node<'_>, what: &str) -> Result<Option<Solid>> {
    let Some(brep) = node.brep() else { return Ok(None) };
    let api = api()?;
    let layout = c_text("layout id", &crate::Brep::layout_id()?)?;
    let raw = unsafe { (api.cadaclysm_blacksmith_from_brep)(brep.pointer().cast(), layout.as_ptr()) };
    drop(brep);
    Solid::wrap(api, raw, what).map(Some)
}

fn is_identity(m: &[[f64; 4]; 4]) -> bool {
    (0..4).all(|i| (0..4).all(|j| m[i][j] == if i == j { 1.0 } else { 0.0 }))
}

// ---- the chain --------------------------------------------------------------------

enum Held<'a> {
    Borrowed(&'a Solid),
    Owned(Solid),
}

impl Held<'_> {
    fn get(&self) -> &Solid {
        match self {
            Held::Borrowed(solid) => solid,
            Held::Owned(solid) => solid,
        }
    }
}

/// The fluent chain: a frame, the solid built so far, and the face last picked. A
/// build call *replaces* the solid; combine solids explicitly with [`Solid::join`].
/// Every step consumes the chain and returns it, failing at once.
///
/// [`Workplane::from_solid`] borrows the solid it starts from, so the solid is still
/// the caller's to join with what the chain builds on it.
pub struct Workplane<'a> {
    frame: Frame,
    solid: Option<Held<'a>>,
    selected: Option<u32>,
}

impl<'a> Workplane<'a> {
    pub fn xy() -> Workplane<'static> {
        Workplane::on(Frame::XY)
    }

    pub fn xz() -> Workplane<'static> {
        Workplane::on(Frame::XZ)
    }

    pub fn yz() -> Workplane<'static> {
        Workplane::on(Frame::YZ)
    }

    pub fn on(frame: Frame) -> Workplane<'static> {
        Workplane { frame, solid: None, selected: None }
    }

    /// A chain on the XY plane holding `solid`, borrowed.
    pub fn from_solid(solid: &'a Solid) -> Workplane<'a> {
        Workplane { frame: Frame::XY, solid: Some(Held::Borrowed(solid)), selected: None }
    }

    pub fn frame(&self) -> Frame {
        self.frame
    }

    fn set(mut self, solid: Solid) -> Workplane<'a> {
        self.solid = Some(Held::Owned(solid));
        self.selected = None;
        self
    }

    fn held(&self, what: &str) -> Result<&Solid> {
        self.solid
            .as_ref()
            .map(Held::get)
            .ok_or_else(|| Error::new(format!("{what}: the workplane holds no solid (BuildError::Empty)")))
    }

    pub fn cuboid(self, x: f64, y: f64, z: f64) -> Result<Workplane<'a>> {
        let solid = Solid::cuboid(x, y, z)?.place(&self.frame)?;
        Ok(self.set(solid))
    }

    pub fn cylinder(self, r: f64, h: f64) -> Result<Workplane<'a>> {
        let solid = Solid::cylinder(r, h)?.place(&self.frame)?;
        Ok(self.set(solid))
    }

    pub fn extrude(self, profile: &Profile, height: f64) -> Result<Workplane<'a>> {
        let solid = Solid::extrude(profile, &self.frame, height)?;
        Ok(self.set(solid))
    }

    /// The flat sheet `profile` bounds on this workplane's frame -- [`Solid::face`].
    pub fn face(self, profile: &Profile) -> Result<Workplane<'a>> {
        let solid = Solid::face(profile, &self.frame)?;
        Ok(self.set(solid))
    }

    /// About this workplane's own y axis through its origin.
    pub fn revolve(self, profile: &Profile, angle: f64) -> Result<Workplane<'a>> {
        let solid = Solid::revolve(profile, &[self.frame.origin(), self.frame.y()], angle)?;
        Ok(self.set(solid))
    }

    /// Slide the current solid, keeping the face selection: a translation carries every
    /// face along at the same index.
    pub fn translate(mut self, dx: f64, dy: f64, dz: f64) -> Result<Workplane<'a>> {
        let moved = self.held("translate")?.translate(dx, dy, dz)?;
        self.solid = Some(Held::Owned(moved));
        Ok(self)
    }

    /// Pick a face of the current solid.
    pub fn faces(mut self, selector: &Selector) -> Result<Workplane<'a>> {
        self.selected = Some(self.held("faces")?.select_face(selector)?);
        Ok(self)
    }

    /// Adopt the frame on the face last picked; a no-op if none is.
    pub fn on_face(mut self) -> Result<Workplane<'a>> {
        if let (Some(solid), Some(face)) = (&self.solid, self.selected) {
            self.frame = solid.get().face_frame(face)?;
        }
        Ok(self)
    }

    /// The solid built. Where the chain built nothing on the solid it borrowed, a copy
    /// of that solid, the borrowed one staying the caller's.
    pub fn solid(self) -> Result<Solid> {
        match self.solid {
            Some(Held::Owned(solid)) => Ok(solid),
            Some(Held::Borrowed(solid)) => solid.translate(0.0, 0.0, 0.0),
            None => Err(Error::new("solid: nothing was built (BuildError::Empty)")),
        }
    }
}

// ---- STEP -------------------------------------------------------------------------

/// `schema`'s path, where it has no newline and names a regular file.
fn schema_file(schema: &str) -> Option<PathBuf> {
    (!schema.contains('\n')).then(|| PathBuf::from(schema)).filter(|p| p.is_file())
}

/// One STEP file's text, each solid its own body. `schema` is `None` (the kernel's
/// built-in AP203); the path of a schema file, read and sent as EXPRESS text; the bare
/// name of a built-in schema (e.g. `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"`);
/// or a custom schema's own EXPRESS text.
pub fn write_step_text(solids: &[&Solid], schema: Option<&str>, unit: Unit) -> Result<String> {
    let api = api()?;
    let schema = match schema {
        None => None,
        Some(given) => Some(match schema_file(given) {
            Some(file) => {
                let bytes = std::fs::read(&file).map_err(|e| Error::new(format!("schema {}: {e}", file.display())))?;
                CString::new(bytes).map_err(|_| Error::new(format!("schema {} contains a NUL byte", file.display())))?
            }
            None => c_text("schema", given)?,
        }),
    };
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let raw = unsafe {
        (api.cadaclysm_blacksmith_step)(handles.as_ptr(), handles.len(), schema.as_ref().map_or(ptr::null(), |s| s.as_ptr()), unit as u32)
    };
    if raw.is_null() {
        return Err(fail(api, "step"));
    }
    let text = unsafe { text(raw as *const c_char) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(raw) };
    Ok(text)
}

/// One STEP file at `path`, each solid its own body; `schema` as [`write_step_text`].
pub fn write_step(path: impl AsRef<FsPath>, solids: &[&Solid], schema: Option<&str>, unit: Unit) -> Result<()> {
    let path = path.as_ref();
    let text = write_step_text(solids, schema, unit)?;
    std::fs::write(path, text).map_err(|e| Error::new(format!("{}: {e}", path.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_checked_as_python_checks_them() {
        assert_eq!(Frame::xy([0.0; 3]).raw(), Frame::XY.raw());
        assert_eq!(Frame::at([0.0; 3], [0.0, 0.0, 1.0], None).unwrap(), Frame::XY);
        assert_eq!(Frame::at([0.0; 3], [0.0, -1.0, 0.0], None).unwrap(), Frame::XZ);
        assert_eq!(Frame::at([0.0; 3], [1.0, 0.0, 0.0], None).unwrap(), Frame::YZ);
        let left = Frame::new([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0]);
        assert!(left.unwrap_err().message().contains("left-handed"));
        let skew = Frame::new([0.0; 3], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
        assert!(skew.unwrap_err().message().contains("not square"));
        assert_eq!(Frame::XY.offset(5.0).origin(), [0.0, 0.0, 5.0]);
        assert!(!Frame::xz([0.0; 3]).raw().iter().any(|v| v.is_sign_negative() && *v == 0.0));
    }

    #[test]
    fn hex_colours_read_as_python_reads_them() {
        assert_eq!(rgb("#fff").unwrap(), [1.0, 1.0, 1.0]);
        assert_eq!(rgb("ff0000").unwrap(), [1.0, 0.0, 0.0]);
        assert!(rgb("#ff00").is_err());
    }

    #[test]
    fn a_line_edge_has_a_unit_direction() {
        let edge = Edge { index: 0, kind: "line".into(), faces: vec![], segments: vec![[[0.0; 3], [0.0, 0.0, 4.0]]] };
        assert_eq!(edge.direction(), Some([0.0, 0.0, 1.0]));
        let arc = Edge { kind: "circle".into(), ..edge };
        assert_eq!(arc.direction(), None);
    }
}
