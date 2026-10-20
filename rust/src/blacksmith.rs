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
//! but not `Sync`. A kernel from 2026-09-26 on locks those caches and lets threads share
//! a solid; older ones do not, and this crate loads whatever library it finds, so it
//! keeps to the older rule -- a handle is not for two threads at once -- and here
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
//! The C ABI also has a held tessellation (`cadaclysm_blacksmith_tessellation`, its four
//! accessors and a free) that other wrappers use to hand out mesh views outliving a re-mesh or the
//! solid's own close. This crate does not need it: the compiler already holds
//! [`Solid::mesh`]'s borrow, so [`sys`] only declares the six entry points, unused, to keep
//! parity with the other wrappers' bindings.
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

use std::collections::BTreeMap;
use std::ffi::{c_char, CString};
use std::fmt;
use std::path::{Path as FsPath, PathBuf};
use std::ptr::{self, NonNull};
use std::rc::Rc;
use std::sync::Mutex;

use crate::{
    borrowed, groups, groups64, text, Beziers64Data, Error, FreedomAxis, Manifold, Mesh, Mesh64, Motion, Node, OpenOptions, PairKind, Result, Scene,
    StateValue, SvgOptions, SvgView, Up,
};
use crate::view::objects::{polyline_segments, present, Shown};
use crate::view::{current, Camera, ViewOptions};

/// What a solid measures, per unit density, each figure beside a bound on its own error.
///
/// Per unit density is the primitive: a body's weight is `density * volume` and its inertia
/// scales the same way, so [`Mass::weight`] is the only figure that takes one. Nothing here
/// multiplies by a density on your behalf -- an assembly of two materials would have to undo it.
///
/// `volume`, `centroid`, `inertia` and `principal_moments` mean something only where `closed`.
/// Where `accuracy_met` is false the refinement stopped before the accuracy asked for: the
/// figures are honest, they are simply less certain, and the errors say by how much.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Mass {
    /// Closed, so the volume-side figures mean something.
    pub closed: bool,
    /// Every face pointed inward; the figures are given as if they had not.
    pub inverted: bool,
    /// Every error came under the accuracy asked for.
    pub accuracy_met: bool,
    /// Measured on a mesh rather than exact surfaces, so the errors are the rounding floor.
    pub from_mesh: bool,
    pub area: f64,
    /// A bound on `area`'s own error.
    pub area_error: f64,
    pub volume: f64,
    /// A bound on `volume`'s own error.
    pub volume_error: f64,
    pub centroid: [f64; 3],
    /// A bound on the distance from `centroid` to the true centroid.
    pub centroid_error: f64,
    /// Row-major about the centroid, products of inertia negated.
    pub inertia: [[f64; 3]; 3],
    /// A bound on every entry of `inertia`.
    pub inertia_error: f64,
    /// Ascending.
    pub principal_moments: [f64; 3],
    /// Unit, orthogonal, right-handed; row `i` belongs to moment `i`.
    pub principal_axes: [[f64; 3]; 3],
}

impl Mass {
    /// `density * volume`, in whatever units the model and the density agree on.
    pub fn weight(&self, density: f64) -> f64 {
        density * self.volume
    }
}

/// Whether a brep's faces make a manifold, as plain data ([`Brep::manifold`]).


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

/// The profiles of a list the library handed back (null: the last error). Each profile is
/// a handle of its own, freed by its `Drop`; the list goes on every path once read, a
/// failed read's too (the profiles read so far drop with the Err).
fn profile_list(api: &'static Api, list: *mut sys::CadaclysmBlacksmithProfileList, what: &str) -> Result<Vec<Profile>> {
    if list.is_null() {
        return Err(fail(api, what));
    }
    let count = unsafe { (api.cadaclysm_blacksmith_profile_list_count)(list) };
    let found = (0..count)
        .map(|i| Profile::wrap(api, unsafe { (api.cadaclysm_blacksmith_profile_list_get)(list, i) }, "profile_list_get"))
        .collect();
    unsafe { (api.cadaclysm_blacksmith_profile_list_free)(list) };
    found
}

fn c_text(what: &str, value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::new(format!("{what} contains a NUL byte")))
}

/// What the kernel says of a job name with a control character in it -- a NUL, which a C
/// string would otherwise cut the name short at, is refused with it before the library is
/// asked, as the Python SDK does for a `Job` name and a `write_camotics` stem.
const JOB_NUL_NAME: &str = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |";

/// `value` as a C string for a job's name or a CAMotics stem: a NUL is refused in the
/// kernel's words ([`JOB_NUL_NAME`]).
fn job_text(value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::new(JOB_NUL_NAME))
}

/// A kernel colour as the viewer's.
fn rgb32(colour: Option<[f64; 3]>) -> Option<[f32; 3]> {
    colour.map(|[r, g, b]| [r as f32, g as f32, b as f32])
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

/// Set a kernel option, by its name, for the whole process from the next call on:
/// `"boolean.mesh_budget"`, `"boolean.finest_tolerance"`, `"profile_boolean.point_budget"`
/// or `"measure.default_accuracy"`. An error -- and nothing changed -- for a name that is
/// not an option or a value it does not take, saying which and what it takes.
pub fn set_option(name: &str, value: f64) -> Result<()> {
    let api = api()?;
    let given = c_text("option name", name)?;
    if unsafe { (api.cadaclysm_blacksmith_option_set)(given.as_ptr(), value) } {
        Ok(())
    } else {
        Err(fail(api, &format!("option {name:?} refused")))
    }
}

/// A kernel option's value, by its name: what [`set_option`] last set, else its default.
/// An error for a name that is not an option, listing the ones there are.
pub fn option(name: &str) -> Result<f64> {
    let api = api()?;
    let given = c_text("option name", name)?;
    let mut out = 0.0f64;
    if unsafe { (api.cadaclysm_blacksmith_option_get)(given.as_ptr(), &mut out) } {
        Ok(out)
    } else {
        Err(fail(api, &format!("no option {name:?}")))
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

    /// Twelve raw numbers as a `Frame`, **unchecked**: every other constructor refuses a
    /// frame that is not square or not right-handed, which is exactly what a test of the
    /// library's *own* "right-handed and orthonormal" refusal (a mirrored raw frame,
    /// spec §5 fact 7) must get past -- `Frame::of` would catch a left-handed one first,
    /// in this crate's own words, and the library's message would never be seen. Not for
    /// building: nothing here checks the axes are even directions, let alone square.
    #[doc(hidden)]
    pub fn raw_unchecked(v: [f64; 12]) -> Frame {
        Frame { v }
    }

    /// The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.
    pub fn midplane(a: &Frame, b: &Frame) -> Result<Frame> {
        let api = api()?;
        let mut out = [0.0; 12];
        if !unsafe { (api.cadaclysm_blacksmith_frame_midplane)(a.v.as_ptr(), b.v.as_ptr(), out.as_mut_ptr()) } {
            return Err(fail(api, "frame_midplane"));
        }
        Frame::of(out)
    }

    /// The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Fails for three points on one line.
    pub fn through(p: [f64; 3], q: [f64; 3], r: [f64; 3]) -> Result<Frame> {
        let api = api()?;
        let mut out = [0.0; 12];
        if !unsafe { (api.cadaclysm_blacksmith_frame_through)(p.as_ptr(), q.as_ptr(), r.as_ptr(), out.as_mut_ptr()) } {
            return Err(fail(api, "frame_through"));
        }
        Frame::of(out)
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

/// Serialises [`Profile::polylines`] process-wide. The kernel now keeps a profile's
/// polylines behind a lock of its own, once per tolerance, and needs none of this;
/// kernels before 2026-09-26 cached them in a `RefCell` holding one tolerance, which
/// `Profile` being `Sync` would race (a panic, or a copy out of freed arrays). The SDK
/// loads whatever library it finds at run time, so it keeps this lock until no kernel
/// it may load is that old: one uncontended lock per call is cheap next to flattening.
static PROFILE_POLYLINES: Mutex<()> = Mutex::new(());

/// A closed outline with holes (or an open chain, from [`Path::end_open`]), in its own
/// x/y. Immutable: every method returns a new one.
pub struct Profile {
    handle: NonNull<sys::CadaclysmBlacksmithProfile>,
    api: &'static Api,
}

// Immutable once built. The kernel caches on it the arrays `profile_polylines`
// returns; a current kernel locks that cache itself, and for an older one (which
// replaced the arrays at another tolerance, unlocked) `Profile::polylines` holds
// `PROFILE_POLYLINES` across the call and the copy-out.
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

    /// A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its
    /// inner corners on the circle of `inner` (positive, under `outer`), alternating: the
    /// first tip at `angle` radians from the sketch's x axis, the rest counter-clockwise.
    pub fn star(centre: [f64; 2], outer: f64, inner: f64, points: u32, angle: f64) -> Result<Profile> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_star)(centre[0], centre[1], outer, inner, points, angle) };
        Profile::wrap(api, raw, "profile_star")
    }

    /// A spline of `degree` through the control polygon `points` (`weights` one per
    /// point, or `None`). Open, it starts on the first point and ends on the last; closed,
    /// it is periodic -- a closed profile. The degree is lowered to fit the points.
    pub fn spline(points: &[[f64; 2]], degree: u32, weights: Option<&[f64]>, closed: bool) -> Result<Profile> {
        let api = api()?;
        // The library reads exactly one weight per point, whatever the slice holds.
        if let Some(w) = weights.filter(|w| w.len() != points.len()) {
            return Err(Error::new(format!("spline: {} weights for {} points; give one per point", w.len(), points.len())));
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

    /// An outline started on a parabola's arc, from rim to rim: [`Path::parabola`].
    pub fn parabola(vertex: [f64; 2], axis: [f64; 2], focal: f64, from: f64, to: f64) -> Result<Path> {
        Path::parabola(vertex, axis, focal, from, to)
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

    /// This curve cut where the `cutters` cross, touch or run along it -- the sketch
    /// trim's pieces: in order along the curve from its start, each an open profile of
    /// portions of this one's own segments (a line's stretch a line, an arc's an arc, a
    /// spline's the same spline over part of its domain). One piece, this curve, where
    /// nothing cuts it; a closed curve's piece round its start is one piece. Cuts closer
    /// than `tolerance` to each other fold onto one.
    pub fn pieces(&self, cutters: &[&Profile], tolerance: f64) -> Result<Vec<Profile>> {
        let handles: Vec<_> = cutters.iter().map(|p| p.raw()).collect();
        let count = unsafe { (self.api.cadaclysm_blacksmith_profile_piece_count)(self.raw(), handles.as_ptr(), handles.len(), tolerance) };
        if count == 0 {
            return Err(fail(self.api, "profile_piece_count"));
        }
        (0..count)
            .map(|i| Profile::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_profile_piece)(self.raw(), handles.as_ptr(), handles.len(), i, tolerance) }, "profile_piece"))
            .collect()
    }

    /// This curve with piece `piece` of [`pieces`](Self::pieces) taken away -- the sketch
    /// trim: what is left, as open profiles. One for a closed curve (its other pieces run
    /// together from where the removed one ended), the stretches before and after for an
    /// open one, none where the piece was the whole curve. An error names a piece the
    /// curve does not have.
    pub fn trim(&self, cutters: &[&Profile], piece: u32, tolerance: f64) -> Result<Vec<Profile>> {
        let handles: Vec<_> = cutters.iter().map(|p| p.raw()).collect();
        let count = unsafe { (self.api.cadaclysm_blacksmith_profile_trim_count)(self.raw(), handles.as_ptr(), handles.len(), piece, tolerance) };
        if count == 0 && failed(self.api) {
            return Err(fail(self.api, "profile_trim_count"));
        }
        (0..count)
            .map(|i| Profile::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_profile_trim_chain)(self.raw(), handles.as_ptr(), handles.len(), piece, i, tolerance) }, "profile_trim_chain"))
            .collect()
    }

    /// Where this profile's curves cross, touch or run along `other`'s, both read in one
    /// plane, as [`Hit`]s ordered along this profile. Points closer than `tolerance`
    /// merge; two curves within `tolerance` of each other for longer than it are one run
    /// when they part only where one ends or the stretch is flat -- one curve following the
    /// other, offset within `tolerance` or tilted by under about half of it, even where it
    /// leaves mid-both; a tangency or a shallow crossing is one point. A loop that stops
    /// short of its start is an open chain. Python's `tolerance` defaults to 1e-6.
    pub fn hits(&self, other: &Profile, tolerance: f64) -> Result<Vec<Hit>> {
        let hits = unsafe { (self.api.cadaclysm_blacksmith_profile_hits)(self.raw(), other.raw(), tolerance) };
        if hits.is_null() {
            return Err(fail(self.api, "profile_hits"));
        }
        let read = || {
            let count = unsafe { (self.api.cadaclysm_blacksmith_hit_count)(hits) };
            let mut out = Vec::with_capacity(count as usize);
            for i in 0..count {
                let mut raw = sys::CadaclysmBlacksmithHit::default();
                if !unsafe { (self.api.cadaclysm_blacksmith_hit)(hits, i, &mut raw) } {
                    return Err(fail(self.api, "hit"));
                }
                out.push(Hit::from(&raw));
            }
            Ok(out)
        };
        // Read everything, then free on every path, a failed read's too.
        let found = read();
        unsafe { (self.api.cadaclysm_blacksmith_hits_free)(hits) };
        found
    }

    /// The region this profile and `other` share, both read in one plane, as zero or more
    /// profiles -- each boundary counter-clockwise, each hole clockwise, arcs and splines
    /// kept exact. Both must be closed and simple. No shared area is an empty `Vec`. Fails
    /// for a `tolerance` not positive and finite, or a profile open or crossing itself.
    /// Python's `tolerance` defaults to 1e-6.
    pub fn common(&self, other: &Profile, tolerance: f64) -> Result<Vec<Profile>> {
        let list = unsafe { (self.api.cadaclysm_blacksmith_profile_common)(self.raw(), other.raw(), tolerance) };
        profile_list(self.api, list, "profile_common")
    }

    /// This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines
    /// and arcs within `tolerance` of it -- what a G-code writer can say. Lines and arcs pass
    /// through as they are, every loop closes on itself exactly, holes are converted the same
    /// way. Fails for a `tolerance` not positive and finite, or a spline that does not
    /// evaluate. Python's `tolerance` defaults to 0.01.
    pub fn to_arcs(&self, tolerance: f64) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_to_arcs)(self.raw(), tolerance) };
        Profile::wrap(self.api, raw, "profile_to_arcs")
    }

    /// This profile grown by `distance` (shrunk where it is negative), as zero or more
    /// profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving
    /// against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted
    /// to `tolerance` first ([`to_arcs`](Self::to_arcs)). A shrink that eats the whole profile
    /// is an empty `Vec`. Fails for a `distance` not finite, a `tolerance` not positive and
    /// finite, a loop with no sides, or loops that cross or touch. Python's `tolerance`
    /// defaults to 0.01.
    pub fn offset(&self, distance: f64, tolerance: f64) -> Result<Vec<Profile>> {
        let list = unsafe { (self.api.cadaclysm_blacksmith_profile_offset)(self.raw(), distance, tolerance) };
        profile_list(self.api, list, "profile_offset")
    }

    /// `text` set in a font, one profile per closed shape -- a letter with its counters as
    /// holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the baseline
    /// along x from the origin, each outline counter-clockwise and its holes clockwise, a
    /// curved side the font's own cubic Bezier kept exactly: an extruded `O` has curved
    /// walls. `size` is roughly the height of a capital. `font` is a family, optionally
    /// with a style (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the
    /// bundled Liberation Sans Regular -- which also serves when the family is not found;
    /// `font_bytes` a font file's bytes, used instead of `font` when given. `halign` is
    /// `"left"`, `"center"` or `"right"`; `valign` `"baseline"`, `"bottom"`, `"center"` or
    /// `"top"`; `spacing` multiplies the gap between glyphs; `direction` `"ltr"` or
    /// `"rtl"`. Empty text is an empty list. An error for a size or spacing not positive
    /// and finite, an alignment or direction not one of those words, font bytes that are
    /// not a font.
    #[allow(clippy::too_many_arguments)]
    pub fn text(text: &str, size: f64, font: &str, halign: &str, valign: &str, spacing: f64, direction: &str, font_bytes: Option<&[u8]>) -> Result<Vec<Profile>> {
        let api = api()?;
        let (t, f, h, v, d) = (c_text("text", text)?, c_text("font", font)?, c_text("halign", halign)?, c_text("valign", valign)?, c_text("direction", direction)?);
        let (bytes, len) = match font_bytes {
            Some(b) => (b.as_ptr(), b.len()),
            None => (ptr::null(), 0),
        };
        let list = unsafe { (api.cadaclysm_blacksmith_profile_text)(t.as_ptr(), size, f.as_ptr(), bytes, len, h.as_ptr(), v.as_ptr(), spacing, d.as_ptr()) };
        profile_list(api, list, "profile_text")
    }

    pub fn translate(&self, dx: f64, dy: f64) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_translate_profile)(self.raw(), dx, dy) };
        Profile::wrap(self.api, raw, "translate_profile")
    }

    /// This outline coloured `(r, g, b)` in 0..1, or from `"#rgb"`, `"#rrggbb"` or a CSS
    /// colour name (see [`rgb`]): how it is drawn. The verbs that make a profile from
    /// one carry it; a solid made from it takes nothing.
    pub fn coloured(&self, colour: impl Into<Colour>) -> Result<Profile> {
        let [r, g, b] = colour.into().rgb()?;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_coloured)(self.raw(), r, g, b) };
        Profile::wrap(self.api, raw, "profile_coloured")
    }

    /// The outline's colour, or `None`.
    pub fn colour(&self) -> Result<Option<[f64; 3]>> {
        let mut out = [0.0; 3];
        if unsafe { (self.api.cadaclysm_blacksmith_profile_colour)(self.raw(), out.as_mut_ptr()) } {
            return Ok(Some(out));
        }
        if failed(self.api) {
            return Err(fail(self.api, "profile_colour"));
        }
        Ok(None)
    }

    /// The outline, then each hole, as polylines at z = 0 within `tolerance` of its arcs
    /// and splines -- what a viewer draws it with. A closed loop repeats its first point
    /// at the end; an open chain (a profile ended open) stays open. Copied out.
    pub fn polylines(&self, tolerance: f64) -> Result<Vec<Vec<[f32; 3]>>> {
        // Held until the arrays are copied out: under an older kernel, another thread
        // asking this profile at another tolerance would replace them under us.
        let _cache = PROFILE_POLYLINES.lock().unwrap_or_else(|p| p.into_inner());
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_polylines)(self.raw(), tolerance) };
        if raw.offsets.is_null() {
            return Err(fail(self.api, "profile_polylines"));
        }
        // SAFETY: the arrays belong to the profile until it is freed or asked again; they
        // are copied out before this call returns.
        let (points, offsets) = unsafe {
            (
                groups::<3>(raw.points, raw.point_count as usize).unwrap_or(&[]),
                borrowed(raw.offsets, raw.polyline_count as usize + 1),
            )
        };
        Ok(offsets.windows(2).map(|w| points.get(w[0] as usize..w[1] as usize).unwrap_or(&[]).to_vec()).collect())
    }

    /// Draw the outline and holes with the view library in use ([`crate::view::current`]),
    /// from the top by default, as lines. `options.edges` is ignored: the lines are the
    /// picture. On the terminal one still; elsewhere a window this call waits on.
    pub fn show<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<()> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        let (segments, rgb) = self.segments(options)?;
        present(current()?, Shown::Lines(segments, rgb), options, "Profile", SvgView::Top, Up::Z, false).map(|_| ())
    }

    /// Orbit the outline until the window is closed; where the camera was left.
    pub fn view<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<Camera> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        let (segments, rgb) = self.segments(options)?;
        present(current()?, Shown::Lines(segments, rgb), options, "Profile", SvgView::Top, Up::Z, true)?
            .ok_or_else(|| Error::new("view: the view library gave back no camera"))
    }

    /// The outline and holes as segments at `options.tolerance`, and the profile's colour.
    pub(crate) fn segments(&self, options: &ViewOptions) -> Result<(Vec<[[f32; 3]; 2]>, Option<[f32; 3]>)> {
        let runs = self.polylines(options.tolerance.unwrap_or(DEFAULT_TOLERANCE))?;
        Ok((polyline_segments(&runs), rgb32(self.colour()?)))
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

    /// This profile's own loops as SVG text, from the camera `options` describes -- see
    /// [`svg_text_of`]. A profile lies in `z = 0`, so its own plane already is the page:
    /// with `options` left `None` the view defaults to [`SvgView::Top`], not
    /// [`SvgOptions::default`]'s own `Iso` -- a solid has no plane of its own to prefer,
    /// so [`Solid::svg_text`] keeps that default. Passing any `SvgOptions` at all, even
    /// one left at [`SvgView::Iso`], opts out of the `Top` default: once built, an
    /// `&SvgOptions` carries no way to tell an explicit `Iso` from a field the caller
    /// never touched, so the choice is made by whether an options value was passed at
    /// all, not by inspecting one.
    pub fn svg_text<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<String> {
        let top = SvgOptions { view: SvgView::Top, ..Default::default() };
        svg_text_of(&[], &[self], options.into().unwrap_or(&top))
    }

    /// This profile written to an SVG file at `path`, by the library itself -- see
    /// [`Profile::svg_text`] for the `Top` default.
    pub fn svg<'o>(&self, path: impl AsRef<FsPath>, options: impl Into<Option<&'o SvgOptions>>) -> Result<()> {
        let top = SvgOptions { view: SvgView::Top, ..Default::default() };
        svg_of(path, &[], &[self], options.into().unwrap_or(&top))
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

    /// Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and
    /// focal length `focal`, over the across-axis coordinates `from..to`: the path begins
    /// at the arc's first point and holds the arc -- a reflector from rim to rim,
    /// `Path::parabola([0.0, 0.0], [0.0, 1.0], 20.0, -50.0, 50.0)` a dish 100 wide
    /// opening up.
    pub fn parabola(vertex: [f64; 2], axis: [f64; 2], focal: f64, from: f64, to: f64) -> Result<Path> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_path_parabola)(vertex[0], vertex[1], axis[0], axis[1], focal, from, to) };
        NonNull::new(raw).map(|handle| Path { handle, api }).ok_or_else(|| fail(api, "path_parabola"))
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

    /// A conic arc to (`x`, `y`) through the control point `control` with middle weight
    /// `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the
    /// rational quadratic Bezier, kept exact.
    pub fn conic_to(self, x: f64, y: f64, control: [f64; 2], weight: f64) -> Result<Path> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_path_conic_to)(self.handle.as_ptr(), x, y, control[0], control[1], weight)
        };
        self.step(ok, "path_conic_to")
    }

    /// A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: [`conic_to`]
    /// with weight 1.
    ///
    /// [`conic_to`]: Path::conic_to
    pub fn parabola_to(self, x: f64, y: f64, control: [f64; 2]) -> Result<Path> {
        self.conic_to(x, y, control, 1.0)
    }

    /// A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1.
    pub fn hyperbola_to(self, x: f64, y: f64, control: [f64; 2], weight: f64) -> Result<Path> {
        if !(weight > 1.0) {
            return Err(Error::new("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)"));
        }
        self.conic_to(x, y, control, weight)
    }

    /// The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length solved
    /// from the two ends. Fails when no parabola with that vertex passes through both.
    pub fn parabola_by_vertex(self, x: f64, y: f64, vertex: [f64; 2]) -> Result<Path> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_path_parabola_by_vertex)(self.handle.as_ptr(), x, y, vertex[0], vertex[1])
        };
        self.step(ok, "path_parabola_by_vertex")
    }

    /// The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends, the
    /// one whose vertex lies between the ends' projections, then the one whose arc cups
    /// the focus (the focus between the arc and its chord), then the more symmetric; with
    /// the focus beyond the chord that is the arch over the ends, not the shallow dish --
    /// draw that one with [`parabola`](Self::parabola).
    pub fn parabola_by_focus(self, x: f64, y: f64, focus: [f64; 2]) -> Result<Path> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_path_parabola_by_focus)(self.handle.as_ptr(), x, y, focus[0], focus[1])
        };
        self.step(ok, "path_parabola_by_focus")
    }

    /// `control`: every control point after the current one, the endpoint last;
    /// `weights`: one per control point *including* the current one, or `None`;
    /// `knots`: the full repeated knot vector.
    pub fn nurbs_to(self, control: &[[f64; 2]], knots: &[f64], degree: u32, weights: Option<&[f64]>) -> Result<Path> {
        // The library reads one weight per control point plus the current point's.
        if let Some(w) = weights.filter(|w| w.len() != control.len() + 1) {
            return Err(Error::new(format!(
                "nurbs_to: {} weights for {} control points (the current point and {} given); give one per point",
                w.len(),
                control.len() + 1,
                control.len()
            )));
        }
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

/// One edge's, or one intersection chain's, exact curve as plain data copied out
/// ([`Edge::curve`], [`Chain::curve`]): `kind` is `"line"`, `"circle"`, `"ellipse"` or
/// `"nurbs"`.
///
/// `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
/// `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
/// `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in
/// the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
/// `radius2 = radius` for a circle); a NURBS's knot parameter
/// (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for
/// conics; for a line `x` is the direction with length = the line's length and `y, z`
/// are zero.
///
/// For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is
/// 0 and `knots`, `poles` are empty. `knots.len() == poles.len() + degree as usize + 1`;
/// `weights` is one per pole, or `None` for a non-rational (plain B-spline) curve, a
/// conic or a line.
#[derive(Clone, Debug, PartialEq)]
pub struct Curve {
    pub kind: String,
    pub origin: [f64; 3],
    pub x: [f64; 3],
    pub y: [f64; 3],
    pub z: [f64; 3],
    pub radius: f64,
    pub radius2: f64,
    pub t0: f64,
    pub t1: f64,
    pub degree: u32,
    pub knots: Vec<f64>,
    pub poles: Vec<[f64; 3]>,
    pub weights: Option<Vec<f64>>,
}

impl Curve {
    /// Copied out of the C struct: the pointers are read here and nowhere kept.
    ///
    /// # Safety
    /// `raw` as `cadaclysm_blacksmith_edge_curve` filled it, its solid still alive.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithCurve) -> Curve {
        let p = |q: sys::CadaclysmBlacksmithPoint| [q.x, q.y, q.z];
        let n = raw.pole_count as usize;
        Curve {
            kind: text(raw.kind),
            origin: p(raw.origin),
            x: p(raw.x),
            y: p(raw.y),
            z: p(raw.z),
            radius: raw.radius,
            radius2: raw.radius2,
            t0: raw.t0,
            t1: raw.t1,
            degree: raw.degree,
            knots: borrowed(raw.knots, raw.knot_count as usize).to_vec(),
            poles: borrowed(raw.poles, 3 * n).chunks_exact(3).map(|q| [q[0], q[1], q[2]]).collect(),
            weights: (!raw.weights.is_null()).then(|| borrowed(raw.weights, n).to_vec()),
        }
    }
}

/// What [`Solid::hits`] found, copied out: `hits` (ordered along the profile;
/// `a_start`/`a_end` on the profile, `b_start`/`b_end` on the solid's faces: a `face` at
/// (`u`, `v`)) and `pieces` (empty for an open body).
pub struct SolidHits {
    pub hits: Vec<Hit>,
    pub pieces: Vec<Piece>,
}

/// One stretch of a profile loop between two cuts ([`SolidHits::pieces`]): `inside` (by
/// its middle's winding number over the body; a piece lying on the surface is inside),
/// `start`/`end` (profile spots -- a segment join reads as the next segment's start
/// `(k + 1, 0)`, an open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is
/// one closed piece) and `profile`, the piece's own open chain (what [`SweepPath::along`]
/// with `open` sweeps).
pub struct Piece {
    pub inside: bool,
    pub start: Spot,
    pub end: Spot,
    pub profile: Profile,
}

/// What [`Solid::intersect`] found, copied out: `chains` (one per face pair per branch)
/// and `overlaps` (one per coincident face pair). Both empty where the solids do not meet.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Intersection {
    pub chains: Vec<Chain>,
    pub overlaps: Vec<Overlap>,
}

/// One branch of one face pair's crossing ([`Intersection::chains`]): `points` in walk
/// order (a closed chain does not repeat its first point), `closed`, `faces` (the face in
/// the first solid, the face in the second), `tangent` (the surfaces near-tangent along
/// it, or the snap unsettled -- the points their best estimate) and `curve`, its exact
/// curve over the chain's own `t0..t1`, or `None` where the kernel found none. A chain
/// may stop at a face boundary or a closed curve's seam and continue as another: join
/// chains by matching ends.
#[derive(Clone, Debug, PartialEq)]
pub struct Chain {
    pub points: Vec<[f64; 3]>,
    pub closed: bool,
    pub faces: (u32, u32),
    pub tangent: bool,
    pub curve: Option<Curve>,
}

impl Chain {
    /// Copied out of the C struct: the pointer is read here and nowhere kept.
    ///
    /// # Safety
    /// `raw` as `cadaclysm_blacksmith_intersection_chain` filled it, its result still alive.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithChain, curve: Option<Curve>) -> Chain {
        Chain {
            points: points_of(borrowed(raw.points, 3 * raw.point_count as usize)),
            closed: raw.closed,
            faces: (raw.face_a, raw.face_b),
            tangent: raw.tangent,
            curve,
        }
    }
}

/// A face of the first solid and a face of the second that coincide
/// ([`Intersection::overlaps`]): `faces` and `loops`, the shared region's rings (outer
/// first, holes after; each ring closed without repeating its first point) -- empty for a
/// partial overlap whose outlines cross.
#[derive(Clone, Debug, PartialEq)]
pub struct Overlap {
    pub faces: (u32, u32),
    pub loops: Vec<Vec<[f64; 3]>>,
}

impl Overlap {
    /// Copied out of the C struct: the pointers are read here and nowhere kept.
    ///
    /// # Safety
    /// `raw` as `cadaclysm_blacksmith_intersection_overlap` filled it, its result still alive.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithOverlap) -> Overlap {
        let points = points_of(borrowed(raw.points, 3 * raw.point_count as usize));
        let starts = borrowed(raw.loop_offsets, raw.loop_count as usize);
        let loops = starts
            .iter()
            .enumerate()
            .map(|(r, &start)| {
                let end = starts.get(r + 1).copied().unwrap_or(raw.point_count) as usize;
                points[start as usize..end].to_vec()
            })
            .collect();
        Overlap { faces: (raw.face_a, raw.face_b), loops }
    }
}

/// xyz triples as points.
fn points_of(flat: &[f64]) -> Vec<[f64; 3]> {
    flat.chunks_exact(3).map(|p| [p[0], p[1], p[2]]).collect()
}

/// One edge of a solid, as plain data: its index (what [`Solid::fillet`] takes), its
/// curve kind, the faces meeting on it, its segments' ends, and its exact [`Curve`]
/// (`None` for an edge with no exact curve, kind `"other"`).
#[derive(Clone, Debug, PartialEq)]
pub struct Edge {
    pub index: u32,
    pub kind: String,
    pub faces: Vec<u32>,
    pub segments: Vec<[[f64; 3]; 2]>,
    pub curve: Option<Curve>,
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

/// Where a hit lands on one side: a profile's `loop_index` (0 the boundary or the open
/// chain, then the holes in the order they were added), `segment`, and `t` from 0 to 1
/// along it, with `face` [`NONE`] -- or a solid's `face` at (`u`, `v`), with
/// `loop_index` and `segment` [`NONE`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Spot {
    pub loop_index: u32,
    pub segment: u32,
    pub t: f64,
    pub face: u32,
    pub u: f64,
    pub v: f64,
}

/// One place two curves meet, copied out. A point (`run` false): `start` equals `end`,
/// and `touch` is true where the curves are tangent rather than crossing. A run (`run`
/// true): they coincide from `start` to `end`. `a_start`/`a_end` are where on the first
/// curve, `b_start`/`b_end` where on the second.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hit {
    pub run: bool,
    pub touch: bool,
    pub start: [f64; 3],
    pub end: [f64; 3],
    pub a_start: Spot,
    pub a_end: Spot,
    pub b_start: Spot,
    pub b_end: Spot,
}

impl From<&sys::CadaclysmBlacksmithSpot> for Spot {
    fn from(s: &sys::CadaclysmBlacksmithSpot) -> Spot {
        Spot { loop_index: s.loop_index, segment: s.segment, t: s.t, face: s.face, u: s.u, v: s.v }
    }
}

impl From<&sys::CadaclysmBlacksmithHit> for Hit {
    fn from(r: &sys::CadaclysmBlacksmithHit) -> Hit {
        Hit {
            run: r.run,
            touch: r.touch,
            start: [r.start.x, r.start.y, r.start.z],
            end: [r.end.x, r.end.y, r.end.z],
            a_start: (&r.a_start).into(),
            a_end: (&r.a_end).into(),
            b_start: (&r.b_start).into(),
            b_end: (&r.b_end).into(),
        }
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

/// A colour as `coloured` and the view's calls take it: numbers in 0..1, or text -- `"#rgb"`,
/// `"#rrggbb"` or a CSS colour name, read by the library's own parser (the kernel's for
/// `coloured`, the view library's for a [`View`](crate::view::View)).
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum Colour {
    Rgb([f64; 3]),
    Text(String),
}

impl From<[f64; 3]> for Colour {
    fn from(c: [f64; 3]) -> Self {
        Colour::Rgb(c)
    }
}

impl From<[f32; 3]> for Colour {
    fn from(c: [f32; 3]) -> Self {
        Colour::Rgb(c.map(f64::from))
    }
}

impl From<&str> for Colour {
    fn from(t: &str) -> Self {
        Colour::Text(t.to_owned())
    }
}

impl From<String> for Colour {
    fn from(t: String) -> Self {
        Colour::Text(t)
    }
}

impl Colour {
    fn rgb(self) -> Result<[f64; 3]> {
        match self {
            Colour::Rgb(c) => Ok(c),
            Colour::Text(t) => rgb(&t),
        }
    }
}

/// The library's own colour parse, shared by [`rgb`] and [`packed`] rather than
/// duplicating the call: `Some((r, g, b))` in 0..1, or `None` for text the library refuses.
fn parse_colour(colour: &str) -> Result<Option<[f64; 3]>> {
    let api = api()?;
    let colour_text = c_text("colour", colour)?;
    let mut out = [0.0f64; 3];
    if unsafe { (api.cadaclysm_blacksmith_parse_colour)(colour_text.as_ptr(), out.as_mut_ptr()) } {
        Ok(Some(out))
    } else {
        Ok(None)
    }
}

/// Colour text -- `"#rgb"`, `"#rrggbb"` (the `#` optional) or a CSS colour name, matched
/// ASCII case-insensitively -- as `(r, g, b)` in 0..1, read by the library's own parser.
pub fn rgb(colour: &str) -> Result<[f64; 3]> {
    parse_colour(colour)?.ok_or_else(|| {
        Error::new(format!(
            "coloured: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or (r, g, b) in 0..1, not {colour:?}"
        ))
    })
}

/// A colour packed `0xRRGGBB` from `"#rgb"`, `"#rrggbb"` or a CSS colour name, read by
/// the library's own parser -- for callers that want the kernel's parser without going
/// through a paint entry point.
pub fn packed(colour: &str) -> Result<u32> {
    let [r, g, b] = parse_colour(colour)?.ok_or_else(|| {
        Error::new(format!("colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '{colour}'"))
    })?;
    Ok(((r * 255.0).round() as u32) << 16 | ((g * 255.0).round() as u32) << 8 | (b * 255.0).round() as u32)
}

// ---- solids -----------------------------------------------------------------------

/// An exact B-rep solid (or open sheet). Immutable: every operation returns a new one.
/// Dropping it frees it. `Send`, not `Sync` -- see the module docs.
pub struct Solid {
    handle: NonNull<sys::CadaclysmBlacksmithSolid>,
    api: &'static Api,
}

// A solid owns its brep reference and its caches outright, so it may move to another
// thread. It is not `Sync`: kernels before 2026-09-26 cache its tessellation in an unlocked
// `RefCell`, and this crate may load one of those (the module docs).
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

    /// The solid's C handle, for libraries that take a `CadaclysmBlacksmithSolid *` --
    /// `cadaclysm_view_show_solid`. Valid until this `Solid` is dropped; the pointee is opaque.
    pub fn as_ptr(&self) -> *const std::ffi::c_void {
        self.handle.as_ptr().cast()
    }

    fn next(&self, raw: *mut sys::CadaclysmBlacksmithSolid, what: &str) -> Result<Solid> {
        Solid::wrap(self.api, raw, what)
    }

    /// Free it now rather than at the end of scope.
    pub fn close(self) {}

    // -- naming

    /// This solid, named `name`. The name rides through an operation with exactly one
    /// source solid (`place`, `translate`, `coloured`, `fillet`, ...) and is dropped by
    /// one with two or more (`join`, `cut`, `common`, ...) and by a fresh primitive or
    /// sweep -- see [`Solid::name`]. It is what [`Assembly::place_solid`] defaults a
    /// placement's own name to, and the product name a lone named solid gets when
    /// written to STEP ([`Solid::step`]/[`Solid::step_text`]). Refused for an empty name.
    pub fn named(&self, name: &str) -> Result<Solid> {
        let name = c_text("name", name)?;
        self.next(unsafe { (self.api.cadaclysm_blacksmith_named)(self.raw(), name.as_ptr()) }, "named")
    }

    /// This solid's name, or `None` if it has none -- what [`named`](Self::named) set,
    /// kept or dropped by whatever built this solid. The C function's pointer is
    /// borrowed and null for both "no name" and a failure, so this reads it directly
    /// and never consults `last_error` -- `text()` would map null to `""`, which would
    /// erase the "no name" case.
    pub fn name(&self) -> Option<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_name)(self.raw()) };
        (!raw.is_null()).then(|| unsafe { text(raw) })
    }

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

    /// A right pyramid of `sides` sides (at least 3): its base the regular polygon of
    /// circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).
    pub fn pyramid(sides: u32, r: f64, h: f64) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_pyramid)(sides, r, h) }, "pyramid")
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

    /// The solid smooth through every section -- a profile on its frame, in order: each
    /// wall interpolates its side across all the profiles (cubic through four or more,
    /// quadratic through three, `loft` through two), capped by the first and the last.
    pub fn loft_through(sections: &[(&Profile, &Frame)]) -> Result<Solid> {
        Self::lofted_through(sections, true)
    }

    /// `loft_through` without the caps: the sheet through the curves.
    pub fn loft_through_open(sections: &[(&Profile, &Frame)]) -> Result<Solid> {
        Self::lofted_through(sections, false)
    }

    fn lofted_through(sections: &[(&Profile, &Frame)], solid: bool) -> Result<Solid> {
        let api = api()?;
        let handles: Vec<_> = sections.iter().map(|(p, _)| p.raw()).collect();
        let frames: Vec<f64> = sections.iter().flat_map(|(_, f)| f.v).collect();
        let (call, what) = if solid { (api.cadaclysm_blacksmith_loft_through, "loft_through") } else { (api.cadaclysm_blacksmith_loft_through_open, "loft_through_open") };
        let raw = unsafe { call(handles.as_ptr(), frames.as_ptr(), handles.len()) };
        Solid::wrap(api, raw, what)
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

    /// This solid scaled by `factor` about the origin: every length times `factor`, exactly.
    pub fn scaled(&self, factor: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_scaled)(self.raw(), factor) }, "scaled")
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
    /// faces the join leaves.
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

    /// This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into
    /// profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a circle
    /// crossing kept exact and any other curve as lines within `tolerance`. A plane that
    /// misses the solid is an empty `Vec`. Fails for a `z` not finite, a `tolerance` not
    /// positive and finite, a face lying in the plane (section a little above or below it), or
    /// a crossing that does not close. Python's `tolerance` defaults to 0.05.
    pub fn section(&self, z: f64, tolerance: f64) -> Result<Vec<Profile>> {
        let list = unsafe { (self.api.cadaclysm_blacksmith_solid_section)(self.raw(), z, tolerance) };
        profile_list(self.api, list, "solid_section")
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

    /// Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as an
    /// [`Intersection`]: `chains` along the curves the faces meet on and `overlaps` where
    /// a face pair coincides. Neither solid is changed; either may be an open sheet. No
    /// crossing is an empty result, never an error.
    ///
    /// Each [`Chain`]'s points are within `tolerance` of both faces' exact surfaces; there
    /// is one chain per face pair per branch -- chains are not joined across a face
    /// boundary or a closed curve's seam, so join them by matching ends. A chain's `curve`
    /// is its exact curve where the kernel found one every point lies within `tolerance`
    /// of, else `None`; `tangent` is set where the surfaces are near-tangent along the
    /// chain or the snap did not settle (the points are then the best estimate) -- a
    /// closed chain that does not go once round its own curve (a sliver where two surfaces
    /// barely cross) has no curve, `tangent` still true. An [`Overlap`] is a coincident
    /// face pair with the shared region's rings (outer first, holes after), which may be
    /// empty for a partial overlap whose outlines cross. Known limit: a crossing narrower
    /// than `tolerance` -- two surfaces passing within it without their meshes crossing --
    /// can be missed; near-tangent contact is where this bites.
    ///
    /// Fails for a `tolerance` not positive and finite, a solid with no faces, or one that
    /// meshes to nothing. Python's `tolerance` defaults to 0.05.
    pub fn intersect(&self, other: &Solid, tolerance: f64) -> Result<Intersection> {
        let found = unsafe { (self.api.cadaclysm_blacksmith_intersect)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        if found.is_null() {
            return Err(fail(self.api, "intersect"));
        }
        let read = || {
            let count = unsafe { (self.api.cadaclysm_blacksmith_intersection_chain_count)(found) };
            let mut chains = Vec::with_capacity(count as usize);
            for i in 0..count {
                let mut raw = sys::CadaclysmBlacksmithChain::default();
                if !unsafe { (self.api.cadaclysm_blacksmith_intersection_chain)(found, i, &mut raw) } {
                    return Err(fail(self.api, "intersection_chain"));
                }
                let curve = if raw.has_curve {
                    let mut raw_curve = sys::CadaclysmBlacksmithCurve::default();
                    if !unsafe { (self.api.cadaclysm_blacksmith_intersection_curve)(found, i, &mut raw_curve) } {
                        return Err(fail(self.api, "intersection_curve"));
                    }
                    // SAFETY: the curve's arrays live in the result until it is freed below.
                    Some(unsafe { Curve::from_raw(&raw_curve) })
                } else {
                    None
                };
                // SAFETY: as above; everything is copied out before the free.
                chains.push(unsafe { Chain::from_raw(&raw, curve) });
            }
            let count = unsafe { (self.api.cadaclysm_blacksmith_intersection_overlap_count)(found) };
            let mut overlaps = Vec::with_capacity(count as usize);
            for i in 0..count {
                let mut raw = sys::CadaclysmBlacksmithOverlap::default();
                if !unsafe { (self.api.cadaclysm_blacksmith_intersection_overlap)(found, i, &mut raw) } {
                    return Err(fail(self.api, "intersection_overlap"));
                }
                // SAFETY: as above.
                overlaps.push(unsafe { Overlap::from_raw(&raw) });
            }
            Ok(Intersection { chains, overlaps })
        };
        // Read everything, then free on every path, a failed read's too.
        let result = read();
        unsafe { (self.api.cadaclysm_blacksmith_intersection_free)(found) };
        result
    }

    /// Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its
    /// loops cut into, as a [`SolidHits`]. Neither is changed.
    ///
    /// A point hit lies within `tolerance` of the segment's exact curve and of the face's
    /// exact surface, inside the face's trim; its profile spot (`a_start`: loop, segment,
    /// t) and face spot (`b_start`: face, u, v) evaluate to the point within `tolerance`;
    /// `touch` where the curve's tangent lies within 1e-3 (sine) of the surface's tangent
    /// plane there (a graze), false at a crossing. A run is a stretch of one segment lying
    /// within `tolerance` of one face and inside it, longer than `tolerance`. Hits within
    /// `tolerance` of each other merge (a hit at a segment join reported once, as
    /// `(k, t = 1)`; a closed loop's closing join reads `(0, 0)`). Every point is in
    /// world space (the frame applied).
    ///
    /// Pieces only for a closed body -- an open body has none -- in loop order, covering
    /// every loop exactly; a piece's spots read a segment join as the next segment's start
    /// `(k + 1, 0)`, and an open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit
    /// cuts is one closed piece. `inside` by the piece middle's winding number over the
    /// body's mesh; a piece lying on the surface is inside. Known limit: a segment passing
    /// within `tolerance` of a face without crossing its mesh can be missed (near-tangent
    /// grazes).
    ///
    /// Fails for a `tolerance` not positive and finite, a solid with no faces or that
    /// meshes to nothing, a profile with no segments, or a free-form segment that is not an
    /// evaluable NURBS curve. Python's `tolerance` defaults to 0.05.
    pub fn hits(&self, profile: &Profile, frame: &Frame, tolerance: f64) -> Result<SolidHits> {
        let found = unsafe {
            (self.api.cadaclysm_blacksmith_solid_profile_hits)(self.raw(), profile.raw(), frame.v.as_ptr(), tolerance, NO_PROGRESS, ptr::null_mut())
        };
        if found.is_null() {
            return Err(fail(self.api, "solid_profile_hits"));
        }
        let read = || {
            let count = unsafe { (self.api.cadaclysm_blacksmith_hit_count)(found) };
            let mut hits = Vec::with_capacity(count as usize);
            for i in 0..count {
                let mut raw = sys::CadaclysmBlacksmithHit::default();
                if !unsafe { (self.api.cadaclysm_blacksmith_hit)(found, i, &mut raw) } {
                    return Err(fail(self.api, "hit"));
                }
                hits.push(Hit::from(&raw));
            }
            let count = unsafe { (self.api.cadaclysm_blacksmith_hits_piece_count)(found) };
            let mut pieces = Vec::with_capacity(count as usize);
            for i in 0..count {
                let (mut inside, mut start, mut end) = (false, sys::CadaclysmBlacksmithSpot::default(), sys::CadaclysmBlacksmithSpot::default());
                if !unsafe { (self.api.cadaclysm_blacksmith_hits_piece)(found, i, &mut inside, &mut start, &mut end) } {
                    return Err(fail(self.api, "hits_piece"));
                }
                let own = Profile::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_hits_piece_profile)(found, i) }, "hits_piece_profile")?;
                pieces.push(Piece { inside, start: (&start).into(), end: (&end).into(), profile: own });
            }
            Ok(SolidHits { hits, pieces })
        };
        // Read everything, then free on every path, a failed read's too.
        let result = read();
        unsafe { (self.api.cadaclysm_blacksmith_hits_free)(found) };
        result
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
    /// the flush faces merged, as a face extrude does it. A face on a cylinder,
    /// a cone, a sphere or a torus moves out along its normal instead, the surface a step
    /// out -- a boss fatter, a bore or a countersink narrower, a dome fuller -- with the
    /// flat faces beside it carried along; any other curved face is refused.
    pub fn push_pull(&self, face: u32, distance: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_push_pull)(self.raw(), face, distance, tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "push_pull")
    }

    /// Faces `faces` pushed out by `distance` together -- a press-pull on a
    /// selection: each by [`Solid::push_pull`]'s rule for it, one after another, each
    /// found again after the pushes before it renumbered the faces. A box's top and a side
    /// pushed 5 is the box 5 taller and 5 wider; a face on the same curved surface as one
    /// before it, and joined to it, moved with that one and is not pushed twice.
    pub fn push_pull_faces(&self, faces: &[u32], distance: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_push_pull_faces)(self.raw(), faces.as_ptr(), faces.len(), distance, tolerance, NO_PROGRESS, ptr::null_mut())
        };
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

    /// This solid split by the closed `profile` drawn on `frame`, pushed straight
    /// through it along the frame's z both ways: the bodies outside the profile first,
    /// then those inside. Where the plane lies along z does not matter.
    pub fn split_by_profile(&self, profile: &Profile, frame: &Frame, tolerance: f64) -> Result<Vec<Solid>> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_split_by_profile)(self.raw(), profile.raw(), frame.v.as_ptr(), tolerance, NO_PROGRESS, ptr::null_mut())
        };
        self.next(raw, "split_by_profile")?.lumps()
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

    /// The round `face` belongs to -- a fillet's bands, balls and rim bands joined to
    /// that face -- made again at `radius`, as a press-pull on a fillet face:
    /// taken back to the sharp edges it replaced, and those rounded again.
    pub fn refillet(&self, face: u32, radius: f64, tolerance: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_refillet)(self.raw(), face, radius, tolerance) }, "refillet")
    }

    /// The round `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a fillet face.
    pub fn unfillet(&self, face: u32) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_unfillet)(self.raw(), face) }, "unfillet")
    }

    /// The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner
    /// triangles joined to that face -- cut again at `distance`, as a press-pull on
    /// a chamfer face: taken back to the sharp edges it cut, and those bevelled again.
    pub fn rechamfer(&self, face: u32, distance: f64, tolerance: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_rechamfer)(self.raw(), face, distance, tolerance) }, "rechamfer")
    }

    /// The chamfer `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a chamfer face.
    pub fn unchamfer(&self, face: u32) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_unchamfer)(self.raw(), face) }, "unchamfer")
    }

    /// This solid hollowed to walls `thickness` thick, the faces at `open` removed so
    /// the hollow is reachable.
    pub fn shell(&self, thickness: f64, open: &[u32], tolerance: f64) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_shell)(self.raw(), thickness, open.as_ptr(), open.len(), tolerance, NO_PROGRESS, ptr::null_mut())
        };
        self.next(raw, "shell")
    }

    /// This sheet made a solid `thickness` thick: its faces, their
    /// twins moved `thickness` along the faces' normals (against them for a negative
    /// thickness), and a wall round every open edge. A closed sheet thickens to a hollow.
    pub fn thicken(&self, thickness: f64, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_thicken)(self.raw(), thickness, tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "thicken")
    }

    // -- colour

    /// This solid coloured `(r, g, b)` in 0..1, or from `"#rgb"`, `"#rrggbb"` or a CSS
    /// colour name (see [`rgb`]) -- or, with `face`, just that face, whose colour then
    /// wins over the solid's. What is made from a coloured solid inherits its colours.
    pub fn coloured(&self, colour: impl Into<Colour>, face: Option<u32>) -> Result<Solid> {
        let face = self.face_or_none(face, "coloured")?;
        let [r, g, b] = colour.into().rgb()?;
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

    /// This solid with its edges coloured `(r, g, b)` in 0..1, or from `"#rgb"`,
    /// `"#rrggbb"` or a CSS colour name (see [`rgb`]): every edge with `edges` `None`,
    /// else just those (by index, as [`Solid::fillet`] takes them), whose colour then
    /// wins over the all-edges one; `Some(&[])` colours none. Inherited as face colours are.
    pub fn edges_coloured(&self, colour: impl Into<Colour>, edges: Option<&[u32]>) -> Result<Solid> {
        let [r, g, b] = colour.into().rgb()?;
        let (ptr, count) = match edges {
            None => (std::ptr::null(), 0),
            Some(list) => (list.as_ptr(), list.len()),
        };
        // `[].as_ptr()` is dangling but non-null: "none", as the C ABI reads it.
        self.next(unsafe { (self.api.cadaclysm_blacksmith_edges_coloured)(self.raw(), ptr, count, r, g, b) }, "edges_coloured")
    }

    /// Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- or `None`.
    pub fn edge_colour(&self, edge: u32) -> Result<Option<[f64; 3]>> {
        let mut out = [0.0; 3];
        if unsafe { (self.api.cadaclysm_blacksmith_edge_colour)(self.raw(), edge, out.as_mut_ptr()) } {
            return Ok(Some(out));
        }
        if failed(self.api) {
            return Err(fail(self.api, "edge_colour"));
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

    /// Face `face` by what it is, eight doubles: the surface's kind (plane 0, cylinder 1,
    /// cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on
    /// the surface at the face's middle (x y z), the outward normal there (x y z), and the
    /// face's extent -- what a feature made on the face keeps, to find the face again with
    /// [`Solid::find_face`] when the solid has been rebuilt with its faces moved, split or
    /// renumbered. Take it before any move you apply to the solid, and look it up on the
    /// unmoved one.
    pub fn face_ref(&self, face: u32) -> Result<[f64; 8]> {
        let mut out = [0.0; 8];
        if !unsafe { (self.api.cadaclysm_blacksmith_face_ref)(self.raw(), face, out.as_mut_ptr()) } {
            return Err(fail(self.api, "face_ref"));
        }
        Ok(out)
    }

    /// The face `face_ref` (from [`Solid::face_ref`]) refers to: among the faces of that
    /// kind whose surface passes through the point, facing the same way, the one the point
    /// lies in -- or, where it lies in none, the one whose boundary comes nearest. `hint`
    /// is the index the face had, preferred among faces that fit equally well; `tolerance`
    /// how far the point may sit off a surface to still be on it. `None` where the face is
    /// gone.
    pub fn find_face(&self, face_ref: &[f64; 8], hint: Option<u32>, tolerance: f64) -> Result<Option<u32>> {
        let hint = hint.and_then(|h| i32::try_from(h).ok()).unwrap_or(-1);
        let found = unsafe { (self.api.cadaclysm_blacksmith_find_face)(self.raw(), face_ref.as_ptr(), hint, tolerance) };
        match found {
            -2 => Err(fail(self.api, "find_face")),
            f if f < 0 => Ok(None),
            f => Ok(Some(f as u32)),
        }
    }

    /// The solid's axis-aligned box `(min, max)`, at the same cost whatever its size: its
    /// mesh at a thousandth of its own extent, in `f64`, so the box is inside the exact one
    /// and short of it by at most that. Worked out once per solid, apart from the
    /// tessellation `mesh` caches. `bounds_at` is the box of the mesh at a tolerance you name.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        let (mut lo, mut hi) = ([0.0; 3], [0.0; 3]);
        if !unsafe { (self.api.cadaclysm_blacksmith_box)(self.raw(), lo.as_mut_ptr(), hi.as_mut_ptr()) } {
            return Err(fail(self.api, "box"));
        }
        Ok((lo, hi))
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

    /// `bounds_at64(DEFAULT_TOLERANCE)`.
    pub fn bounds64(&self) -> Result<([f64; 3], [f64; 3])> {
        self.bounds_at64(DEFAULT_TOLERANCE)
    }

    /// [`Solid::bounds_at`] from the same tessellation's unnarrowed positions: exact
    /// far from the origin, where `bounds_at`'s widened `f32` positions are not.
    pub fn bounds_at64(&self, tolerance: f64) -> Result<([f64; 3], [f64; 3])> {
        let (mut lo, mut hi) = ([0.0; 3], [0.0; 3]);
        if !unsafe { (self.api.cadaclysm_blacksmith_bounds64)(self.raw(), tolerance, lo.as_mut_ptr(), hi.as_mut_ptr()) } {
            return Err(fail(self.api, "bounds64"));
        }
        Ok((lo, hi))
    }

    /// This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
    /// broad phase's own shape, cheaper to move and test than the solid itself.
    pub fn bounds_box(&self, tolerance: f64) -> Result<Aabb> {
        let mut out = sys::CadaclysmBlacksmithBox { lo: [0.0; 3], hi: [0.0; 3] };
        if !unsafe { (self.api.cadaclysm_blacksmith_solid_bounds_box)(self.raw(), tolerance, &mut out) } {
            return Err(fail(self.api, "bounds_box"));
        }
        Ok(out.into())
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

    /// What this solid measures, per unit density, each figure beside a bound on its own error.
    ///
    /// `accuracy` is relative and 0 asks for the library's default. The volume-side figures mean
    /// something only where [`Mass::closed`]; where `accuracy_met` is false the refinement stopped
    /// early and the figures are honest but less certain, which the errors say.
    pub fn mass(&self, accuracy: f64) -> Result<Mass> {
        let mut raw = sys::CadaclysmBlacksmithMassProperties::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_mass_properties)(self.raw(), accuracy, &mut raw) } {
            return Err(fail(self.api, "mass_properties"));
        }
        let rows = |flat: &[f64; 9]| {
            [[flat[0], flat[1], flat[2]], [flat[3], flat[4], flat[5]], [flat[6], flat[7], flat[8]]]
        };
        Ok(Mass {
            closed: raw.closed != 0,
            inverted: raw.inverted != 0,
            accuracy_met: raw.accuracy_met != 0,
            from_mesh: raw.from_mesh != 0,
            area: raw.area,
            area_error: raw.area_error,
            volume: raw.volume,
            volume_error: raw.volume_error,
            centroid: raw.centroid,
            centroid_error: raw.centroid_error,
            inertia: rows(&raw.inertia),
            inertia_error: raw.inertia_error,
            principal_moments: raw.principal_moments,
            principal_axes: rows(&raw.principal_axes),
        })
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
            let curve = self.edge_curve(index)?;
            edges.push(Edge { index, kind: unsafe { text(raw.kind) }, faces: faces.to_vec(), segments, curve });
        }
        Ok(edges)
    }

    /// Edge `i`'s exact curve copied out, or `None` for an edge with none (the library's
    /// "has no exact curve"); any other refusal is the error.
    fn edge_curve(&self, i: u32) -> Result<Option<Curve>> {
        let mut raw = sys::CadaclysmBlacksmithCurve::default();
        if unsafe { (self.api.cadaclysm_blacksmith_edge_curve)(self.raw(), i, &mut raw) } {
            // SAFETY: the curve table is cached on the solid and never replaced, and
            // everything is copied out before this borrow of `self` ends.
            return Ok(Some(unsafe { Curve::from_raw(&raw) }));
        }
        let err = fail(self.api, "edge_curve");
        if err.to_string().contains("has no exact curve") {
            return Ok(None);
        }
        Err(err)
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

    /// [`Solid::mesh`] in `double`, from the same cache, under the same rule: valid
    /// until the solid is freed or meshed again at a different tolerance.
    pub fn mesh64(&mut self, tolerance: f64) -> Result<Mesh64<'_>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_mesh64)(self.raw(), tolerance) };
        if raw.positions.is_null() {
            return Err(fail(self.api, "mesh64"));
        }
        let n = raw.vertex_count as usize;
        // SAFETY: as `mesh` -- the cache lives until the solid is freed or re-meshed,
        // and the `&mut` borrow this mesh carries rules out both.
        unsafe {
            Ok(Mesh64 {
                positions: groups64::<3>(raw.positions, n).unwrap_or(&[]),
                normals: groups64::<3>(raw.normals, n),
                uvs: None,
                colors: None,
                indices: borrowed(raw.indices, raw.index_count as usize),
            })
        }
    }

    /// This solid meshed for a solver, as a [`FemMesh`]: nodes welded by bits -- two mesh
    /// points are one node only where their coordinates are the same doubles, so no
    /// tolerance ever merges two distinct points and a crack stays a crack -- triangles
    /// wound outward, and every node tagged with the lowest-dimension B-rep entity it lies
    /// on.
    ///
    /// `tolerance` is the chordal tolerance in model units, and **it alone governs how
    /// closely the mesh follows the geometry**. `max_size` is a size ceiling, `0` for none
    /// (curvature alone): it splits boundary segments to at most that length and lays
    /// interior stations `max_size / √2` apart as a **target**, adding nodes without
    /// refining the boundary geometry -- a caller that wants the rim nearer its curve lowers
    /// the `tolerance`. [`FemMesh::longest_edge`] is what the mesh actually came to.
    ///
    /// **Neither is checked here**: both go through as given and the library refuses what it
    /// will not take, in its own words. `0.01` and `0.0` are `FemOptions::default()`, filled
    /// by `cadaclysm_blacksmith_fem_options_init` before either is set, so a field added to
    /// that struct later defaults without this code being touched.
    ///
    /// `placement` is a [`Frame`] -- **twelve** numbers, origin, x, y, z, as every frame
    /// here -- and `None` for the identity, a solid meshed in its own coordinates being the
    /// common case. The reader library's [`crate::Node::fem_mesh`] takes **sixteen**,
    /// column-major, so a caller moving between the two reformats the placement; both are
    /// sized types here, so that confusion does not compile.
    ///
    /// `&self`, not `&mut self`: a FEM mesh is a handle of its own rather than a slice of
    /// the tessellation cache, so unlike [`Solid::mesh`] it neither replaces that cache nor
    /// is staled by it, and the solid stays free to be meshed, written or combined while one
    /// is held.
    ///
    /// The call runs silent: the ABI takes a progress callback for its `meshing` and
    /// `welding` phases, and this passes none, as every progress-taking call in this module
    /// does.
    ///
    /// **A cracked solid is not a failure**: it comes back with [`FemMesh::watertight`]
    /// false and its cracks in [`FemMesh::open_edges`] / [`FemMesh::folded_edges`], and
    /// nothing is welded shut to make it look sound. An error for a tolerance or size the
    /// mesher refuses, a placement that is not finite and invertible, a closed solid this
    /// library cannot mesh, and a solid that meshes to no triangles at all.
    ///
    /// **No unlicensed notice here**: [`FemMesh::msh_text`] and [`FemMesh::save_msh`] print
    /// it, this library noticing on its writers rather than on its builders -- where the
    /// reader library notices in its own constructor and on neither `.msh` call.
    pub fn fem_mesh(&self, tolerance: f64, max_size: f64, placement: Option<&Frame>) -> Result<FemMesh> {
        let mut options = std::mem::MaybeUninit::<sys::CadaclysmBlacksmithFemOptions>::uninit();
        unsafe { (self.api.cadaclysm_blacksmith_fem_options_init)(options.as_mut_ptr()) };
        // SAFETY: `init` writes the library's whole `CadaclysmBlacksmithFemOptions`, which
        // `cadaclysm-capi/tests/bindings.rs` pins to this crate's declaration field for field.
        let mut options = unsafe { options.assume_init() };
        // `size` is then this crate's own, which is what the growth rule asks of a caller.
        options.size = std::mem::size_of::<sys::CadaclysmBlacksmithFemOptions>();
        options.tolerance = tolerance;
        options.max_size = max_size;
        // The twelve doubles, or null for the identity -- the one frame argument in this
        // library that may be left out.
        let frame = placement.map(Frame::raw);
        let matrix = frame.as_ref().map_or(ptr::null(), |f| f.as_ptr());
        FemMesh::wrap(self.api, unsafe {
            (self.api.cadaclysm_blacksmith_fem_mesh)(self.raw(), matrix, &options, NO_PROGRESS, ptr::null_mut())
        })
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

    /// A colour per polyline of [`Solid::edge_polylines`] at the same tolerance, as drawn:
    /// `None` for a polyline on no coloured edge; empty where the solid has no edge paint
    /// at all. Copied out.
    pub fn edge_polyline_colours(&mut self, tolerance: f64) -> Result<Vec<Option<[f64; 3]>>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_edge_polyline_colours)(self.raw(), tolerance) };
        if raw.rgb.is_null() {
            if failed(self.api) {
                return Err(fail(self.api, "edge_polyline_colours"));
            }
            return Ok(Vec::new());
        }
        // SAFETY: `count` triples live in the solid's cache until it is meshed again, as `mesh`.
        let values = unsafe { std::slice::from_raw_parts(raw.rgb, 3 * raw.count as usize) };
        Ok(values.chunks_exact(3).map(|c| (c[0] >= 0.0).then(|| [c[0], c[1], c[2]])).collect())
    }

    /// How many triangles each face meshed to at `tolerance`, one count per face in face
    /// order: [`Solid::mesh`]'s triangles at the same tolerance run face by face. What a
    /// viewer colours a face by. Borrowed from the cache, as the mesh is.
    pub fn face_triangles(&mut self, tolerance: f64) -> Result<&[u32]> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_mesh_face_triangles)(self.raw(), tolerance) };
        if raw.counts.is_null() {
            return Err(fail(self.api, "mesh_face_triangles"));
        }
        // SAFETY: as `mesh`.
        Ok(unsafe { borrowed(raw.counts, raw.face_count as usize) })
    }

    /// Draw the solid with the view library in use ([`crate::view::current`]), by handle:
    /// exact surfaces where they draw, its paint, its edges (`options.edges`). On the
    /// terminal one still in the scrollback; on the wgpu library ([`crate::view::use_wgpu`])
    /// a window this call waits on until it is closed. `None` for `options` is the defaults.
    pub fn show<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<()> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        present(current()?, Shown::Solid(self), options, "Solid", SvgView::Iso, Up::Z, false).map(|_| ())
    }

    /// Orbit the solid until the window is closed; where the camera was left.
    pub fn view<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<Camera> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        present(current()?, Shown::Solid(self), options, "Solid", SvgView::Iso, Up::Z, true)?
            .ok_or_else(|| Error::new("view: the view library gave back no camera"))
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

    /// This solid as ACIS SAT text -- see [`write_sat_text`].
    pub fn sat_text(&self, unit: Unit) -> Result<String> {
        write_sat_text(&[self], unit)
    }

    /// This solid written to a SAT file at `path`, by the library itself.
    pub fn sat(&self, path: impl AsRef<FsPath>, unit: Unit) -> Result<()> {
        write_sat(path, &[self], unit)
    }

    /// This solid as OCCT `.brep` text; see [`write_brep_text`].
    pub fn brep_text(&self) -> Result<String> {
        write_brep_text(&[self])
    }

    /// This solid written to a `.brep` file at `path`, by the library itself.
    pub fn brep(&self, path: impl AsRef<FsPath>) -> Result<()> {
        write_brep(path, &[self])
    }

    /// This solid's wireframe as SVG text, from the camera `options` describes -- the
    /// library's own camera, not a viewer. See [`write_svg_text`].
    pub fn svg_text<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<String> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        write_svg_text(&[self], options)
    }

    /// This solid written to an SVG file at `path`, by the library itself.
    pub fn svg<'o>(&self, path: impl AsRef<FsPath>, options: impl Into<Option<&'o SvgOptions>>) -> Result<()> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        write_svg(path, &[self], options)
    }

    /// This solid's silhouette -- where its surfaces turn away from the eye, which no edge of it
    /// lies on -- as rational cubic Béziers in `double`, from the camera `options` describes
    /// (`None` for [`SvgOptions::default`]). The same [`SvgOptions`] that draw a picture:
    /// `view`, `azimuth`, `elevation`, `up` and `fov`, and `width` with `tolerance`, which the
    /// library reads together as the page fraction `tolerance / width`. Nothing else in them
    /// changes the curves.
    ///
    /// The library hands over an owned block; this copies it out and releases it before it
    /// returns, on every path (see [`SilhouetteBlock`]), so there is nothing for the caller to
    /// free.
    ///
    /// A body with no silhouette (every face planar) is an empty answer, not an error; a refused
    /// option or a body with no measurable geometry is an `Err`.
    pub fn silhouette_beziers<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<Beziers64Data> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let raw = build_svg_options(self.api, options)?;
        let mut count = 0u32;
        let data = unsafe { (self.api.cadaclysm_blacksmith_silhouette_beziers)(self.raw(), &raw, &mut count) };
        if data.is_null() {
            // The library clears the thread's error at entry and the empty answer sets none: a
            // reason here is this call's own refusal, none is the empty answer.
            if failed(self.api) {
                return Err(fail(self.api, "silhouette_beziers"));
            }
            return Ok(Beziers64Data::default());
        }
        // From here the block is owned by the guard, which frees it when this function returns
        // by any path -- the end below, or a panic while copying.
        let block = SilhouetteBlock { api: self.api, data, count };
        let doubles = unsafe { std::slice::from_raw_parts(block.data, block.count as usize * 16) };
        let mut out = Beziers64Data::default();
        for curve in doubles.chunks_exact(16) {
            out.points.extend(curve[..12].chunks_exact(3).map(|p| [p[0], p[1], p[2]]));
            out.weights.extend_from_slice(&curve[12..]);
        }
        Ok(out)
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

// ---- machining ----------------------------------------------------------------------

/// The library's own default for [`Job::new`]'s `clearance`.
pub const JOB_DEFAULT_CLEARANCE: f64 = 1.0;
/// The library's own default for [`Job::new`]'s `tolerance`.
pub const JOB_DEFAULT_TOLERANCE: f64 = 0.01;
/// The library's own default for [`Job::new`]'s `name`.
pub const JOB_DEFAULT_NAME: &str = "job";
/// The library's own default for [`Job::new`]'s `spindle_dwell`, in seconds.
pub const JOB_DEFAULT_SPINDLE_DWELL: f64 = 2.0;
/// The library's own default for [`Job::new`]'s `resolution`, in mm.
pub const JOB_DEFAULT_RESOLUTION: f64 = 0.1;
/// The library's own default ramp angle for [`Tool::flat`] and [`Tool::ball`], in degrees.
pub const TOOL_DEFAULT_RAMP_ANGLE: f64 = 3.0;

/// A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `flute_length` in
/// mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
/// `ramp_angle` degrees. Immutable; a job keeps its own copy, so dropping a tool a job has
/// used changes nothing there. Dropping it frees it.
pub struct Tool {
    handle: NonNull<sys::CadaclysmBlacksmithTool>,
    api: &'static Api,
}

unsafe impl Send for Tool {}

impl Drop for Tool {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_tool_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Tool {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Tool({:p})", self.handle)
    }
}

impl Tool {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithTool, what: &str) -> Result<Tool> {
        NonNull::new(raw).map(|handle| Tool { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithTool {
        self.handle.as_ptr()
    }

    /// A flat end mill: Grbl tool `number` (at least 1), `diameter` and `flute_length` in mm,
    /// `feed` and `plunge` in mm/min, `rpm` its spindle speed. It ramps into its cuts at
    /// `ramp_angle` degrees ([`TOOL_DEFAULT_RAMP_ANGLE`] is the library's own). Fails for a
    /// `number` of 0 or above 255, a size, feed or speed not positive and finite, or a
    /// `ramp_angle` outside (0, 90].
    pub fn flat(number: u32, diameter: f64, flute_length: f64, feed: f64, plunge: f64, rpm: f64, ramp_angle: f64) -> Result<Tool> {
        let api = api()?;
        let made = unsafe { (api.cadaclysm_blacksmith_tool_flat)(number, diameter, flute_length, feed, plunge, rpm) };
        ramped(api, made, ramp_angle, "tool_flat")
    }

    /// A ball end mill, as [`Tool::flat`], its tip a half sphere of the diameter; in 2.5D it
    /// cuts where a flat does, `bottom` being the tip.
    pub fn ball(number: u32, diameter: f64, flute_length: f64, feed: f64, plunge: f64, rpm: f64, ramp_angle: f64) -> Result<Tool> {
        let api = api()?;
        let made = unsafe { (api.cadaclysm_blacksmith_tool_ball)(number, diameter, flute_length, feed, plunge, rpm) };
        ramped(api, made, ramp_angle, "tool_ball")
    }

    /// A drill: as [`Tool::flat`], plunging at `feed`. A job takes it for [`Job::drill`] (and
    /// [`Job::machine`]'s drills) only.
    pub fn drill(number: u32, diameter: f64, flute_length: f64, feed: f64, rpm: f64) -> Result<Tool> {
        let api = api()?;
        Tool::wrap(api, unsafe { (api.cadaclysm_blacksmith_tool_drill)(number, diameter, flute_length, feed, rpm) }, "tool_drill")
    }

    /// A new tool: this one, ramping into its cuts at `degrees` from the horizontal instead.
    /// Fails for an angle outside (0, 90].
    pub fn with_ramp_angle(&self, degrees: f64) -> Result<Tool> {
        Tool::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_tool_with_ramp_angle)(self.raw(), degrees) }, "tool_with_ramp_angle")
    }
}

/// `made` wrapped, then turned to `ramp_angle` when it is not the library's own default -- the
/// unramped handle dropped at once rather than kept around.
fn ramped(api: &'static Api, made: *mut sys::CadaclysmBlacksmithTool, ramp_angle: f64, what: &str) -> Result<Tool> {
    let tool = Tool::wrap(api, made, what)?;
    if ramp_angle == TOOL_DEFAULT_RAMP_ANGLE {
        return Ok(tool);
    }
    tool.with_ramp_angle(ramp_angle)
}

/// The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own
/// copy. Dropping it frees it.
pub struct Stock {
    handle: NonNull<sys::CadaclysmBlacksmithStock>,
    api: &'static Api,
}

unsafe impl Send for Stock {}

impl Drop for Stock {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_stock_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Stock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Stock({:p})", self.handle)
    }
}

impl Stock {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithStock, what: &str) -> Result<Stock> {
        NonNull::new(raw).map(|handle| Stock { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithStock {
        self.handle.as_ptr()
    }

    /// The box from `min` (x, y, z) to `max`. Fails unless every min is below its max and all
    /// six are finite. Named `box_`: `box` is a Rust keyword.
    pub fn box_(min: [f64; 3], max: [f64; 3]) -> Result<Stock> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_stock_box)(min[0], min[1], min[2], max[0], max[1], max[2]) };
        Stock::wrap(api, raw, "stock_box")
    }

    /// `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
    /// solid's lowest Z. Fails for a `margin` negative or not finite.
    pub fn around(solid: &Solid, margin: f64) -> Result<Stock> {
        let raw = unsafe { (solid.api.cadaclysm_blacksmith_stock_around)(solid.raw(), margin) };
        Stock::wrap(solid.api, raw, "stock_around")
    }
}

/// One file a job wrote: a Grbl program (`tool` its `T` number, `name` `<job name>-T<n>`, or
/// `<job name>-<k>-T<n>` for a repeated tool) from [`Job::gcode`], or one of
/// [`Job::write_camotics`]'s files (`tool` 0 for the simulation copies and the project).
/// Copied out; immutable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Program {
    pub tool: u32,
    pub name: String,
    pub text: String,
}

/// One operation of a [`Job`], read back by [`Job::operations`]: `kind` (`"face"`,
/// `"contour"`, `"pocket"` or `"drill"`), `tool` (its Grbl `T` number) and `params`, a
/// [`BTreeMap`] (sorted, for a stable order) of the operation's own arguments in the
/// library's own numbers -- `side` 0 outside, 1 inside or 2 on its line; `climb` and `open` 1
/// or 0; `points` a count; a `peck` of none is `None`. Copied out; immutable.
#[derive(Clone, Debug, PartialEq)]
pub struct Operation {
    pub kind: String,
    pub tool: u32,
    pub params: BTreeMap<String, Option<f64>>,
}

/// One thing [`Job::machine`] left uncut, one of [`Report`]'s items. Copied out; immutable.
#[derive(Debug)]
pub struct ReportItem {
    /// `"corner"` (material the end mill doesn't reach), `"hole"` (a round hole no drill
    /// matches or a matched drill can't make), `"slope"` (a face that is neither horizontal
    /// nor vertical, cut as steps), `"undercut"` (material under an overhang) or `"too_deep"`
    /// (a level below the end mill's flute length, cut only that far).
    pub kind: String,
    /// The item's XYZ location -- a centroid for an area, the axis point at the top for a
    /// hole.
    pub at: [f64; 3],
    /// An area in mm^2 for `corner`/`undercut`, a diameter in mm for `hole`, and a height in
    /// mm (its Z range) for `slope` and `too_deep`.
    pub size: f64,
    /// One sentence naming the cause and the tool involved.
    pub reason: String,
    /// The XY area the item covers.
    pub region: Vec<Profile>,
}

/// What [`Job::machine`] could not make: [`items`](Self::items), in order, read once when
/// `machine` returns, and the kernel's own [`Display`](fmt::Display) -- one line per item, or
/// `"nothing left uncut"`. Copied out; immutable.
#[derive(Debug)]
pub struct Report {
    items: Vec<ReportItem>,
    text: String,
}

impl Report {
    /// What [`Job::machine`] left uncut, in order.
    pub fn items(&self) -> &[ReportItem] {
        &self.items
    }

    /// [`items`](Self::items), consumed: for a caller (the Godot wrapper, which builds its
    /// own owned records from them rather than borrowing) that wants the `Vec` itself.
    pub fn into_items(self) -> Vec<ReportItem> {
        self.items
    }

    /// Whether nothing was left uncut (no items).
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// The kernel's own text: one line per item, or `"nothing left uncut"`. The same as
    /// [`Display`](fmt::Display), spelled out.
    pub fn text(&self) -> &str {
        &self.text
    }
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}

/// A machining job on a [`Stock`]: operations kept in the order they are added, written as
/// one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation is
/// added in place, and a refused one leaves the job as it was. `safe_z` is the absolute Z of
/// rapids between operations and at a program's start and end, above the stock's top;
/// `clearance` is how far above an operation's top it enters and leaves its passes;
/// `tolerance` fits free-form sides and offsets; `name` names the programs (`<name>-T<n>`);
/// `spindle_dwell` is how long every program waits after starting the spindle; `resolution`
/// is the CAMotics project's voxel size in mm. Dropping it frees it -- there is no `close` of
/// its own; drop is the close.
pub struct Job {
    handle: NonNull<sys::CadaclysmBlacksmithJob>,
    api: &'static Api,
}

unsafe impl Send for Job {}

impl Drop for Job {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_job_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Job {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Job({:p})", self.handle)
    }
}

/// `side`'s library code, or the refusal for any other side -- checked here so a bad spelling never
/// reaches the library.
fn job_side(side: &str) -> Result<u32> {
    match side {
        "outside" => Ok(0),
        "inside" => Ok(1),
        "on" => Ok(2),
        _ => Err(Error::new("side must be 'outside', 'inside' or 'on'")),
    }
}

/// The files of one `job_gcode`/`job_camotics` call, copied out, the list freed.
fn programs(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithPrograms, what: &str) -> Result<Vec<Program>> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let count = unsafe { (api.cadaclysm_blacksmith_programs_count)(raw) };
    let out = (0..count)
        .map(|i| Program {
            tool: unsafe { (api.cadaclysm_blacksmith_programs_tool)(raw, i) },
            name: unsafe { text((api.cadaclysm_blacksmith_programs_name)(raw, i)) },
            text: unsafe { text((api.cadaclysm_blacksmith_programs_text)(raw, i)) },
        })
        .collect();
    unsafe { (api.cadaclysm_blacksmith_programs_free)(raw) };
    Ok(out)
}

/// A `job_machine` report, read field by field, the report freed.
fn read_report(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithReport) -> Result<Report> {
    let read = || -> Result<Report> {
        let count = unsafe { (api.cadaclysm_blacksmith_report_count)(raw) };
        let mut items = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut at = [0.0; 3];
            if !unsafe { (api.cadaclysm_blacksmith_report_at)(raw, i, at.as_mut_ptr()) } {
                return Err(fail(api, "report_at"));
            }
            let region = profile_list(api, unsafe { (api.cadaclysm_blacksmith_report_region)(raw, i) }, "report_region")?;
            items.push(ReportItem {
                kind: unsafe { text((api.cadaclysm_blacksmith_report_kind)(raw, i)) },
                at,
                size: unsafe { (api.cadaclysm_blacksmith_report_size)(raw, i) },
                reason: unsafe { text((api.cadaclysm_blacksmith_report_reason)(raw, i)) },
                region,
            });
        }
        let text = unsafe { text((api.cadaclysm_blacksmith_report_text)(raw)) };
        Ok(Report { items, text })
    };
    let found = read();
    unsafe { (api.cadaclysm_blacksmith_report_free)(raw) };
    found
}

/// Every operation of one `job_operations` call, read field by field, the list freed.
fn read_operations(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithOperations) -> Vec<Operation> {
    let count = unsafe { (api.cadaclysm_blacksmith_operations_count)(raw) };
    let out = (0..count)
        .map(|i| {
            let param_count = unsafe { (api.cadaclysm_blacksmith_operations_param_count)(raw, i) };
            let params = (0..param_count)
                .map(|k| {
                    let name = unsafe { text((api.cadaclysm_blacksmith_operations_param_name)(raw, i, k)) };
                    let value = unsafe { (api.cadaclysm_blacksmith_operations_param_value)(raw, i, k) };
                    (name, (!value.is_nan()).then_some(value))
                })
                .collect();
            Operation {
                kind: unsafe { text((api.cadaclysm_blacksmith_operations_kind)(raw, i)) },
                tool: unsafe { (api.cadaclysm_blacksmith_operations_tool)(raw, i) },
                params,
            }
        })
        .collect();
    unsafe { (api.cadaclysm_blacksmith_operations_free)(raw) };
    out
}

impl Job {
    /// An empty job on `stock`, rapids at `safe_z` (above the stock's top). Fails for a
    /// `safe_z` not above the stock's top, or a setting the job refuses.
    #[allow(clippy::too_many_arguments)]
    pub fn new(stock: &Stock, safe_z: f64, clearance: f64, tolerance: f64, name: &str, spindle_dwell: f64, resolution: f64) -> Result<Job> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_job_new)(stock.raw(), safe_z) };
        let job = Job { handle: NonNull::new(raw).ok_or_else(|| fail(api, "job_new"))?, api };
        let jp = job.raw();
        if !unsafe { (api.cadaclysm_blacksmith_job_set_clearance)(jp, clearance) } {
            return Err(fail(api, "job_set_clearance"));
        }
        if !unsafe { (api.cadaclysm_blacksmith_job_set_tolerance)(jp, tolerance) } {
            return Err(fail(api, "job_set_tolerance"));
        }
        if !unsafe { (api.cadaclysm_blacksmith_job_set_spindle_dwell)(jp, spindle_dwell) } {
            return Err(fail(api, "job_set_spindle_dwell"));
        }
        if !unsafe { (api.cadaclysm_blacksmith_job_set_resolution)(jp, resolution) } {
            return Err(fail(api, "job_set_resolution"));
        }
        let cname = job_text(name)?;
        if !unsafe { (api.cadaclysm_blacksmith_job_set_name)(jp, cname.as_ptr()) } {
            return Err(fail(api, "job_set_name"));
        }
        Ok(job)
    }

    fn raw(&self) -> *mut sys::CadaclysmBlacksmithJob {
        self.handle.as_ptr()
    }

    /// Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes
    /// at most `stepdown` deep, with `tool`. Fails for a drill, a `z` above the stock's top, a
    /// stepover past the tool's diameter, or what the job otherwise refuses.
    pub fn face(&mut self, tool: &Tool, z: f64, stepover: f64, stepdown: f64) -> Result<()> {
        let ok = unsafe { (self.api.cadaclysm_blacksmith_job_face)(self.raw(), tool.raw(), z, stepover, stepdown) };
        if ok { Ok(()) } else { Err(fail(self.api, "job_face")) }
    }

    /// Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
    /// `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb
    /// milling, else conventional; `open` to cut the outline as an open chain (only "on" its
    /// line, and with no holes). Fails for any other `side`, or what the job otherwise
    /// refuses.
    #[allow(clippy::too_many_arguments)]
    pub fn contour(&mut self, tool: &Tool, profile: &Profile, top: f64, bottom: f64, side: &str, stepdown: f64, climb: bool, open: bool) -> Result<()> {
        let code = job_side(side)?;
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_job_contour)(self.raw(), tool.raw(), profile.raw(), top, bottom, code, stepdown, climb, open)
        };
        if ok { Ok(()) } else { Err(fail(self.api, "job_contour")) }
    }

    /// Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
    /// rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep,
    /// with `tool`. Fails for what the job refuses; a pocket too small for the tool is refused
    /// by [`gcode`](Self::gcode), naming the operation.
    pub fn pocket(&mut self, tool: &Tool, profile: &Profile, top: f64, bottom: f64, stepover: f64, stepdown: f64) -> Result<()> {
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_job_pocket)(self.raw(), tool.raw(), profile.raw(), top, bottom, stepover, stepdown)
        };
        if ok { Ok(()) } else { Err(fail(self.api, "job_pocket")) }
    }

    /// A hole at each (x, y) of `points`, from `top` to `bottom` with `tool`, pecking `peck`
    /// deep at a time (retracting between pecks), or straight to depth for `None`. Fails for
    /// what the job refuses (a tool that is not a drill, no points, ...).
    pub fn drill(&mut self, tool: &Tool, points: &[[f64; 2]], top: f64, bottom: f64, peck: Option<f64>) -> Result<()> {
        let xy: *const f64 = if points.is_empty() { ptr::null() } else { points.as_ptr().cast() };
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_job_drill)(self.raw(), tool.raw(), xy, points.len(), top, bottom, peck.unwrap_or(f64::NAN))
        };
        if ok { Ok(()) } else { Err(fail(self.api, "job_drill")) }
    }

    /// Recognise `part` and append the operations that make it: faced, contoured and pocketed
    /// with `end_mill`, its holes drilled with whichever of `drills` fits each -- a tool per
    /// required diameter. A `None` element of `drills` is the library's own "null drill <i>".
    /// `stepover` and `stepdown` of `None` are the kernel's own defaults; `skin` (at least 0)
    /// is how far above the part's lowest point the outline stops, so the part stays attached
    /// to the stock -- 0 cuts through; `peck` of `None` is none (a drill straight to depth).
    /// Returns a [`Report`] of what could not be cut. Fails for what the kernel refuses (a
    /// drill as `end_mill`, a null drill, ...); the job changes only on success -- a refusal
    /// leaves it exactly as it was.
    #[allow(clippy::too_many_arguments)]
    pub fn machine(
        &mut self,
        part: &Solid,
        end_mill: &Tool,
        drills: &[Option<&Tool>],
        stepover: Option<f64>,
        stepdown: Option<f64>,
        skin: f64,
        peck: Option<f64>,
    ) -> Result<Report> {
        let handles: Vec<*const sys::CadaclysmBlacksmithTool> = drills.iter().map(|t| t.map_or(ptr::null(), Tool::raw)).collect();
        let drills_ptr = if handles.is_empty() { ptr::null() } else { handles.as_ptr() };
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_job_machine)(
                self.raw(),
                part.raw(),
                end_mill.raw(),
                drills_ptr,
                handles.len(),
                stepover.unwrap_or(f64::NAN),
                stepdown.unwrap_or(f64::NAN),
                skin,
                peck.unwrap_or(f64::NAN),
            )
        };
        if raw.is_null() {
            return Err(fail(self.api, "job_machine"));
        }
        read_report(self.api, raw)
    }

    /// Every operation added to this job so far, in order -- whether added by
    /// [`face`](Self::face), [`contour`](Self::contour), [`pocket`](Self::pocket),
    /// [`drill`](Self::drill) or [`machine`](Self::machine).
    pub fn operations(&self) -> Result<Vec<Operation>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_job_operations)(self.raw()) };
        if raw.is_null() {
            return Err(fail(self.api, "job_operations"));
        }
        Ok(read_operations(self.api, raw))
    }

    /// The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool
    /// (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k`
    /// of a tool that runs more than once); an empty `Vec` for a job with no operations.
    /// Fails for an operation whose geometry the tool cannot cut (named by its index and
    /// kind).
    pub fn gcode(&self) -> Result<Vec<Program>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_job_gcode)(self.raw()) };
        programs(self.api, raw, "job_gcode")
    }

    /// `job_camotics(stem)`, copied out.
    fn camotics_files(&self, stem: &str) -> Result<Vec<Program>> {
        let cstem = job_text(stem)?;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_job_camotics)(self.raw(), cstem.as_ptr()) };
        programs(self.api, raw, "job_camotics")
    }

    /// A CAMotics project at `path` and its files beside it, named after the project's file
    /// stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each program, a
    /// simulation copy of it (`.sim.nc`, which the project lists), and the project last.
    /// Creates the directory. Returns the paths written, the project last, written here (not
    /// by the library) byte for byte, as plain UTF-8 with no byte-order mark. Fails for a
    /// path with no file stem, what [`gcode`](Self::gcode) refuses, or a file that cannot be
    /// written.
    pub fn write_camotics(&self, path: impl AsRef<FsPath>) -> Result<Vec<PathBuf>> {
        let path = path.as_ref();
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| Error::new(format!("job_camotics: {} has no file stem", path.display())))?;
        let files = self.camotics_files(stem)?;
        let dir = path.parent().filter(|d| !d.as_os_str().is_empty());
        if let Some(dir) = dir {
            std::fs::create_dir_all(dir).map_err(|e| Error::new(format!("job_camotics: {}: {e}", path.display())))?;
        }
        let dir = dir.unwrap_or_else(|| FsPath::new(""));
        let mut written = Vec::with_capacity(files.len());
        for (i, file) in files.iter().enumerate() {
            let at = if i + 1 == files.len() { path.to_path_buf() } else { dir.join(&file.name) };
            std::fs::write(&at, &file.text).map_err(|e| Error::new(format!("job_camotics: {}: {e}", path.display())))?;
            written.push(at);
        }
        Ok(written)
    }
}

// ---- collider -----------------------------------------------------------------------

/// An axis-aligned box: `lo` and `hi`, three numbers each. The broad phase's own shape
/// ([`Solid::bounds_box`], [`Collider`]'s own boxes): cheap to move and to test against
/// another, before anything is meshed. Named `Aabb` rather than `Box`, which the
/// standard library reserves.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Aabb {
    pub lo: [f64; 3],
    pub hi: [f64; 3],
}

impl From<sys::CadaclysmBlacksmithBox> for Aabb {
    fn from(r: sys::CadaclysmBlacksmithBox) -> Aabb {
        Aabb { lo: r.lo, hi: r.hi }
    }
}

fn box_words(b: Aabb) -> sys::CadaclysmBlacksmithBox {
    sys::CadaclysmBlacksmithBox { lo: b.lo, hi: b.hi }
}

impl Aabb {
    pub fn new(lo: [f64; 3], hi: [f64; 3]) -> Aabb {
        Aabb { lo, hi }
    }

    /// This box moved by `frame` (rigid), boxed again on the world axes -- not this
    /// box's corners individually moved, which would not in general be a box at all:
    /// the *bounding* box of the moved corners.
    pub fn moved(&self, frame: &Frame) -> Result<Aabb> {
        let api = api()?;
        let raw = box_words(*self);
        let mut out = sys::CadaclysmBlacksmithBox { lo: [0.0; 3], hi: [0.0; 3] };
        if !unsafe { (api.cadaclysm_blacksmith_box_moved)(&raw, frame.raw().as_ptr(), &mut out) } {
            return Err(fail(api, "box_moved"));
        }
        Ok(out.into())
    }

    /// Whether this box and `other` share a point (touching counts).
    pub fn overlaps(&self, other: &Aabb) -> Result<bool> {
        let api = api()?;
        let a = box_words(*self);
        let b = box_words(*other);
        Ok(unsafe { (api.cadaclysm_blacksmith_box_overlaps)(&a, &b) })
    }
}

/// True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch -- a
/// separating axis among the boxes' face normals and edge-direction crosses; touching
/// is not apart. Sharper than moving each box and asking [`Aabb::overlaps`], which boxes
/// the *result* on the world axes again and so can call two oriented boxes overlapping
/// when they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3
/// along x: their world boxes overlap, but the boxes themselves do not touch).
pub fn boxes_apart(a: &Aabb, frame_a: &Frame, b: &Aabb, frame_b: &Frame) -> Result<bool> {
    let api = api()?;
    let ra = box_words(*a);
    let rb = box_words(*b);
    let mut apart = false;
    if !unsafe { (api.cadaclysm_blacksmith_boxes_apart)(&ra, frame_a.raw().as_ptr(), &rb, frame_b.raw().as_ptr(), &mut apart) } {
        return Err(fail(api, "boxes_apart"));
    }
    Ok(apart)
}

/// Counts of one [`Collider::check`] call: the candidate pairs `considered`, how many
/// of them the world boxes and the oriented boxes cleared, how many the share left to
/// another call, how the rest were answered (`cached`, `closed_form`, `meshed`), and
/// how many were `refused`. `confirmed` is the subset of `meshed` that were thin
/// mesh-path overlaps sent to [`Solid::common`] itself for a final answer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ColliderStats {
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

impl From<sys::CadaclysmBlacksmithColliderStats> for ColliderStats {
    fn from(r: sys::CadaclysmBlacksmithColliderStats) -> ColliderStats {
        ColliderStats {
            considered: r.considered,
            world_boxes: r.world_boxes,
            oriented_boxes: r.oriented_boxes,
            skipped_share: r.skipped_share,
            cached: r.cached,
            closed_form: r.closed_form,
            meshed: r.meshed,
            refused: r.refused,
            confirmed: r.confirmed,
        }
    }
}

/// Keeps one [`Collider::check`] answer alive for as long as any [`CollisionHit`] of it
/// is: each hit holds a clone of this (`Rc`), and the last one dropped frees the handle
/// -- a `CollisionHit` needs the handle itself back for `solid()`.
struct CollisionsHandle {
    handle: NonNull<sys::CadaclysmBlacksmithCollisions>,
    api: &'static Api,
}

impl Drop for CollisionsHandle {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_collisions_free)(self.handle.as_ptr()) }
    }
}

/// One pair [`Collider::check`] found overlapping (`overlap` true), or could not
/// decide (`overlap` false; `text` says why, empty for an overlap). `positions`/
/// `normals` are world xyz triples, three per triangle (unwelded); `indices` indexes
/// them -- all empty for a refused pair. `depth` is the thinnest side of the overlap's
/// world box, 0 for a refused pair.
///
/// `solid()` rebuilds the exact overlap now, from the frames `check` found it at; this
/// keeps the collisions handle behind every hit of one `check` call alive until the
/// last of them is dropped, freeing it only then.
pub struct CollisionHit {
    pub a: u32,
    pub b: u32,
    pub overlap: bool,
    /// `"overlap"` or `"refused"` -- the same answer as `overlap`, spelled the way
    /// every other `kind` in this module is.
    pub kind: String,
    pub depth: f64,
    pub text: String,
    pub positions: Vec<[f64; 3]>,
    pub normals: Vec<[f64; 3]>,
    pub indices: Vec<u32>,
    keeper: Rc<CollisionsHandle>,
    index: u32,
}

impl fmt::Debug for CollisionHit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CollisionHit")
            .field("a", &self.a)
            .field("b", &self.b)
            .field("overlap", &self.overlap)
            .field("kind", &self.kind)
            .field("depth", &self.depth)
            .field("text", &self.text)
            .finish()
    }
}

impl CollisionHit {
    /// Copied out of the C struct: the pointers are read here and nowhere kept.
    ///
    /// # Safety
    /// `raw` as `cadaclysm_blacksmith_collisions_hit` filled it, its result still alive.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithCollisionHit, keeper: Rc<CollisionsHandle>, index: u32) -> CollisionHit {
        CollisionHit {
            a: raw.a,
            b: raw.b,
            overlap: raw.overlap,
            kind: if raw.overlap { "overlap".to_string() } else { "refused".to_string() },
            depth: raw.depth,
            text: text(raw.text),
            positions: points_of(borrowed(raw.positions, 3 * raw.vertex_count as usize)),
            normals: points_of(borrowed(raw.normals, 3 * raw.vertex_count as usize)),
            indices: borrowed(raw.indices, raw.index_count as usize).to_vec(),
            keeper,
            index,
        }
    }

    /// The exact overlap of this pair at the frames [`Collider::check`] found it at,
    /// as a new solid. Fails for a refused pair (`overlap` false) or a collisions
    /// handle already closed some other way.
    pub fn solid(&self) -> Result<Solid> {
        let raw = unsafe { (self.keeper.api.cadaclysm_blacksmith_collisions_solid)(self.keeper.handle.as_ptr(), self.index) };
        Solid::wrap(self.keeper.api, raw, "collisions_solid")
    }
}

/// Parts meshed once, asked pose after pose which of them interfere: `solids` at rest,
/// meshed at `tolerance`; `groups` one group index per solid (`None`: each solid its
/// own group -- [`Collider::check`] then takes one frame per solid), `allowed` pairs of
/// part indices never tested (designed contacts). Dropping it frees the handle.
pub struct Collider {
    handle: NonNull<sys::CadaclysmBlacksmithCollider>,
    api: &'static Api,
}

unsafe impl Send for Collider {}

impl Drop for Collider {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_collider_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Collider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Collider({:p})", self.handle)
    }
}

impl Collider {
    /// `solids` at rest, meshed at `tolerance`; `groups` one group index per solid
    /// (`None`: each solid its own group), `allowed` pairs of part indices never
    /// tested (designed contacts, by part index).
    pub fn new(solids: &[&Solid], tolerance: f64, groups: Option<&[u32]>, allowed: &[(u32, u32)]) -> Result<Collider> {
        if let Some(groups) = groups {
            if groups.len() != solids.len() {
                return Err(Error::new(format!(
                    "Collider: groups must have one entry per solid ({} solids, {} groups)",
                    solids.len(),
                    groups.len()
                )));
            }
        }
        let api = api()?;
        let handles: Vec<*const sys::CadaclysmBlacksmithSolid> = solids.iter().map(|s| s.raw()).collect();
        let allowed_flat: Vec<u32> = allowed.iter().flat_map(|&(a, b)| [a, b]).collect();
        let groups_ptr = groups.map(|g| g.as_ptr()).unwrap_or(ptr::null());
        let allowed_ptr = if allowed_flat.is_empty() { ptr::null() } else { allowed_flat.as_ptr() };
        let raw = unsafe {
            (api.cadaclysm_blacksmith_collider_new)(
                handles.as_ptr(),
                handles.len() as u32,
                tolerance,
                groups_ptr,
                allowed_ptr,
                allowed.len() as u32,
            )
        };
        NonNull::new(raw).map(|handle| Collider { handle, api }).ok_or_else(|| fail(api, "collider_new"))
    }

    fn raw(&self) -> *mut sys::CadaclysmBlacksmithCollider {
        self.handle.as_ptr()
    }

    /// How many groups this collider has -- the highest group index past the
    /// constructor, plus one.
    pub fn group_count(&self) -> u32 {
        unsafe { (self.api.cadaclysm_blacksmith_collider_group_count)(self.raw()) }
    }

    /// Counts of the last [`Collider::check`] call (all zero before the first one).
    pub fn stats(&self) -> Result<ColliderStats> {
        let mut out = sys::CadaclysmBlacksmithColliderStats::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_collider_stats)(self.raw(), &mut out) } {
            return Err(fail(self.api, "collider_stats"));
        }
        Ok(out.into())
    }

    /// The pairs that interfere, or could not be decided, with each group placed at
    /// its matching frame in `frames` (one per group, in group order). `share`:
    /// `None`, every pair past the box filters is decided now; `Some((k, n))`, only
    /// those whose index is `k` modulo `n` (the shares of one pose are disjoint and
    /// cover it -- split one `check` across `n` workers).
    pub fn check(&self, frames: &[Frame], share: Option<(u32, u32)>) -> Result<Vec<CollisionHit>> {
        let flat: Vec<f64> = frames.iter().flat_map(|f| f.raw()).collect();
        let (share_k, share_n) = share.unwrap_or((0, 0));
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_collider_check)(self.raw(), flat.as_ptr(), frames.len() as u32, share_k, share_n)
        };
        let Some(handle) = NonNull::new(raw) else { return Err(fail(self.api, "collider_check")) };
        let count = unsafe { (self.api.cadaclysm_blacksmith_collisions_count)(handle.as_ptr()) };
        if count == 0 {
            unsafe { (self.api.cadaclysm_blacksmith_collisions_free)(handle.as_ptr()) };
            return Ok(Vec::new());
        }
        let keeper = Rc::new(CollisionsHandle { handle, api: self.api });
        let mut hits = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut raw_hit = sys::CadaclysmBlacksmithCollisionHit::default();
            if !unsafe { (self.api.cadaclysm_blacksmith_collisions_hit)(keeper.handle.as_ptr(), i, &mut raw_hit) } {
                return Err(fail(self.api, "collisions_hit"));
            }
            hits.push(unsafe { CollisionHit::from_raw(&raw_hit, Rc::clone(&keeper), i) });
        }
        Ok(hits)
    }
}

// ---- SubD cages -------------------------------------------------------------------

/// The plane a mirrored cage is cut on, perpendicular to this axis.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubdAxis {
    X,
    Y,
    Z,
}

impl SubdAxis {
    fn code(self) -> u32 {
        self as u32
    }

    fn from_code(code: i32) -> Option<SubdAxis> {
        match code {
            0 => Some(SubdAxis::X),
            1 => Some(SubdAxis::Y),
            2 => Some(SubdAxis::Z),
            _ => None,
        }
    }
}

/// Which kind of cage element a call means: vertices, edges or faces.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubdElements {
    Vertices,
    Edges,
    Faces,
}

impl SubdElements {
    fn code(self) -> u32 {
        self as u32
    }
}

/// A set of cage elements, by kernel id: vertices, edges (as vertex pairs, smaller id first
/// where the kernel reads them back) or faces. It is what [`Subd::selection`] reads, what
/// [`Subd::transform`] takes, and what [`Subd::pick`] answers (one element).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubdSelection {
    Vertices(Vec<u32>),
    Edges(Vec<(u32, u32)>),
    Faces(Vec<u32>),
}

impl SubdSelection {
    fn kind(&self) -> SubdElements {
        match self {
            SubdSelection::Vertices(_) => SubdElements::Vertices,
            SubdSelection::Edges(_) => SubdElements::Edges,
            SubdSelection::Faces(_) => SubdElements::Faces,
        }
    }

    /// The ids as the C ABI reads them: flat, an edge as two.
    fn flat(&self) -> Vec<u32> {
        match self {
            SubdSelection::Vertices(ids) | SubdSelection::Faces(ids) => ids.clone(),
            SubdSelection::Edges(edges) => flatten_pairs(edges),
        }
    }
}

fn flatten_pairs(pairs: &[(u32, u32)]) -> Vec<u32> {
    pairs.iter().flat_map(|&(a, b)| [a, b]).collect()
}

fn pairs_of(flat: &[u32]) -> Vec<(u32, u32)> {
    flat.chunks_exact(2).map(|p| (p[0], p[1])).collect()
}

/// `n` items at `p` copied out, or none for a null pointer or a zero count (the C ABI leaves
/// the pointer unspecified for an empty run).
///
/// # Safety
/// `p` must be null or point at `n` readable items.
unsafe fn copied<T: Copy>(p: *const T, n: usize) -> Vec<T> {
    if p.is_null() || n == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(p, n).to_vec()
    }
}

/// One level of a cage's smooth surface, copied out of the cage so that it outlives it:
/// [`Subd::smooth_mesh`]'s answer. `positions` and `normals` are limit positions and unit
/// outward limit normals; `indices` is three vertex ids a triangle and `triangle_face` the
/// face of the **full** cage each triangle lies on (on a mirrored half, face `f` of the half
/// is `f` and its reflection `f` plus the half's face count).
#[derive(Clone, Debug, PartialEq)]
pub struct SubdMesh {
    pub positions: Vec<[f64; 3]>,
    pub normals: Vec<[f64; 3]>,
    pub indices: Vec<[u32; 3]>,
    pub triangle_face: Vec<u32>,
}

/// What [`Subd::to_solid`] did and how close it came: `regular` patches exact from their own
/// net and `refined` ones from a refined neighbourhood; the Catmull-Clark `steps` taken first
/// (1 or 2); `levels`, the deepest local refinement a patch took (0 when none was refined);
/// the largest `deviation` from the limit surface, as a fraction of the cage's bounding-box
/// diagonal; the largest tangent break `g1_angle_deg` across a side that is not creased, in
/// degrees; and the world points they were measured at, `deviation_at` and `g1_at`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubdReport {
    pub regular: u32,
    pub refined: u32,
    pub steps: u32,
    pub levels: u32,
    pub deviation: f64,
    pub g1_angle_deg: f64,
    pub deviation_at: [f64; 3],
    pub g1_at: [f64; 3],
}

impl From<sys::CadaclysmBlacksmithSubdReport> for SubdReport {
    fn from(r: sys::CadaclysmBlacksmithSubdReport) -> SubdReport {
        SubdReport {
            regular: r.regular,
            refined: r.refined,
            steps: r.steps,
            levels: r.levels,
            deviation: r.deviation,
            g1_angle_deg: r.g1_angle_deg,
            deviation_at: r.deviation_at,
            g1_at: r.g1_at,
        }
    }
}

/// [`Subd::to_solid`]'s limits. A `tolerance` or `g1_angle` of 0 or less, or a `max_levels` of
/// 0, takes the default, which is also what `Default` holds: 1e-4, 0.1, 6.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubdSolidOptions {
    /// The largest deviation from the limit surface, as a fraction of the cage's diagonal.
    pub tolerance: f64,
    /// The largest tangent break across an uncreased side, in degrees.
    pub g1_angle: f64,
    /// The deepest local refinement (2 to 6).
    pub max_levels: u32,
}

impl Default for SubdSolidOptions {
    fn default() -> SubdSolidOptions {
        SubdSolidOptions { tolerance: 1e-4, g1_angle: 0.1, max_levels: 6 }
    }
}

/// A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an
/// optional mirror plane, and the selection of the edit that made it. Immutable: every edit
/// returns a new `Subd`, whose [`selection`](Subd::selection) names what that edit touched;
/// [`to_solid`](Subd::to_solid) turns it into an exact B-rep. Dropping it frees the handle
/// instead of an explicit close; a cage made from another keeps its own. A refusal is the
/// kernel's own words.
pub struct Subd {
    handle: NonNull<sys::CadaclysmBlacksmithSubd>,
    api: &'static Api,
}

unsafe impl Send for Subd {}

impl Drop for Subd {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_subd_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Subd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Subd({:p})", self.handle)
    }
}

impl Subd {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSubd, what: &str) -> Result<Subd> {
        NonNull::new(raw).map(|handle| Subd { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithSubd {
        self.handle.as_ptr()
    }

    /// A box of `size` (x, y, z), centred on the origin, with `segments` quads along each
    /// axis (1 to 1024).
    pub fn cuboid(size: [f64; 3], segments: [u32; 3]) -> Result<Subd> {
        let api = api()?;
        let raw = unsafe {
            (api.cadaclysm_blacksmith_subd_cuboid)(size[0], size[1], size[2], segments[0], segments[1], segments[2])
        };
        Subd::wrap(api, raw, "subd_cuboid")
    }

    /// A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of
    /// quads between them; with `creased_rims` the two rim loops are creased, so the caps
    /// stay flat. **The other wrappers default `creased_rims` to `true`**, which is what
    /// converts: an uncreased cylinder of 7 or more sides is refused by
    /// [`to_solid`](Subd::to_solid) at the default limits.
    pub fn cylinder(radius: f64, height: f64, sides: u32, rings: u32, creased_rims: bool) -> Result<Subd> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_subd_cylinder)(radius, height, sides, rings, creased_rims) };
        Subd::wrap(api, raw, "subd_cylinder")
    }

    /// A quad ball of `radius`: a cube grid with `segments` quads per edge, each vertex
    /// pushed out to the radius.
    pub fn sphere(radius: f64, segments: u32) -> Result<Subd> {
        let api = api()?;
        Subd::wrap(api, unsafe { (api.cadaclysm_blacksmith_subd_sphere)(radius, segments) }, "subd_sphere")
    }

    /// A torus around +Z: `around` steps about the axis at `major`, `tube` steps round the
    /// tube of `minor`, all quads.
    pub fn torus(major: f64, minor: f64, around: u32, tube: u32) -> Result<Subd> {
        let api = api()?;
        Subd::wrap(api, unsafe { (api.cadaclysm_blacksmith_subd_torus)(major, minor, around, tube) }, "subd_torus")
    }

    /// A cage from its parts, the lossless inverse of reading them back: `positions`, `faces`
    /// (each a loop of vertex ids), `creases` (vertex pairs that are edges), `pins` vertex
    /// ids, and `symmetry` the axis and tolerance of a mirrored half, as
    /// [`symmetry`](Subd::symmetry) reports it. The new cage selects nothing.
    pub fn from_parts<F: AsRef<[u32]>>(
        positions: &[[f64; 3]],
        faces: &[F],
        creases: &[(u32, u32)],
        pins: &[u32],
        symmetry: Option<(SubdAxis, f64)>,
    ) -> Result<Subd> {
        let api = api()?;
        let sizes: Vec<u32> = faces.iter().map(|f| f.as_ref().len() as u32).collect();
        let loops: Vec<u32> = faces.iter().flat_map(|f| f.as_ref().iter().copied()).collect();
        let crease_ids = flatten_pairs(creases);
        let (axis, tolerance) = match symmetry {
            Some((axis, tolerance)) => (axis.code() as i32, tolerance),
            None => (-1, 0.0),
        };
        let raw = unsafe {
            (api.cadaclysm_blacksmith_subd_from_parts)(
                positions.as_ptr().cast(),
                positions.len() as u32,
                sizes.as_ptr(),
                sizes.len() as u32,
                loops.as_ptr(),
                loops.len() as u32,
                crease_ids.as_ptr(),
                creases.len() as u32,
                pins.as_ptr(),
                pins.len() as u32,
                axis,
                tolerance,
            )
        };
        Subd::wrap(api, raw, "subd_from_parts")
    }

    /// `read` over this cage's parts while their views into the handle are alive.
    fn with_parts<R>(&self, read: impl FnOnce(&sys::CadaclysmBlacksmithSubdParts) -> R) -> Result<R> {
        let mut out = sys::CadaclysmBlacksmithSubdParts::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_subd_parts)(self.raw(), &mut out) } {
            return Err(fail(self.api, "subd_parts"));
        }
        Ok(read(&out))
    }

    /// The cage's vertices: a copy.
    pub fn positions(&self) -> Result<Vec<[f64; 3]>> {
        self.with_parts(|p| {
            let flat: Vec<f64> = unsafe { copied(p.positions, 3 * p.vertex_count as usize) };
            flat.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect()
        })
    }

    /// Each face's vertex ids, in loop order.
    pub fn faces(&self) -> Result<Vec<Vec<u32>>> {
        self.with_parts(|p| {
            let sizes = unsafe { copied(p.face_sizes, p.face_count as usize) };
            let loops = unsafe { copied(p.face_indices, p.index_count as usize) };
            let mut at = 0;
            sizes
                .iter()
                .map(|&n| {
                    let face = loops[at..at + n as usize].to_vec();
                    at += n as usize;
                    face
                })
                .collect()
        })
    }

    /// The creased edges, each (smaller id, larger id), sorted.
    pub fn creases(&self) -> Result<Vec<(u32, u32)>> {
        self.with_parts(|p| pairs_of(&unsafe { copied(p.creases, 2 * p.crease_count as usize) }))
    }

    /// The pinned vertices: they refine as corners and stay put.
    pub fn pins(&self) -> Result<Vec<u32>> {
        self.with_parts(|p| unsafe { copied(p.pins, p.pin_count as usize) })
    }

    /// `None` for an ordinary cage; for a mirrored half the plane's axis and how far from it
    /// a vertex counts as on it.
    pub fn symmetry(&self) -> Result<Option<(SubdAxis, f64)>> {
        self.with_parts(|p| SubdAxis::from_code(p.symmetry_axis).map(|axis| (axis, p.symmetry_tolerance)))
    }

    /// What the edit that made this cage touched; `None` for a cage no edit selected (a
    /// primitive, [`from_parts`](Subd::from_parts), the mirror calls).
    pub fn selection(&self) -> Result<Option<SubdSelection>> {
        self.with_parts(|p| {
            let n = p.selection_count as usize;
            match p.selection_kind {
                0 => Some(SubdSelection::Vertices(unsafe { copied(p.selection, n) })),
                1 => Some(SubdSelection::Edges(pairs_of(&unsafe { copied(p.selection, 2 * n) }))),
                2 => Some(SubdSelection::Faces(unsafe { copied(p.selection, n) })),
                _ => None,
            }
        })
    }

    fn edit(&self, raw: *mut sys::CadaclysmBlacksmithSubd, what: &str) -> Result<Subd> {
        Subd::wrap(self.api, raw, what)
    }

    /// A new cage with the selected elements moved by `matrix`: sixteen numbers,
    /// column-major, with a rotation about a point baked in by the caller. The new cage
    /// selects the same elements.
    pub fn transform(&self, selection: &SubdSelection, matrix: &[f64]) -> Result<Subd> {
        if matrix.len() != 16 {
            return Err(Error::new(format!("transform matrix: expected 16 numbers, got {}", matrix.len())));
        }
        let ids = selection.flat();
        let count = ids.len() / if selection.kind() == SubdElements::Edges { 2 } else { 1 };
        self.edit(
            unsafe {
                (self.api.cadaclysm_blacksmith_subd_transform)(self.raw(), selection.kind().code(), ids.as_ptr(), count as u32, matrix.as_ptr())
            },
            "subd_transform",
        )
    }

    /// A new cage with `edges` creased, or un-creased when `on` is false; it selects them.
    pub fn crease(&self, edges: &[(u32, u32)], on: bool) -> Result<Subd> {
        let flat = flatten_pairs(edges);
        self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_set_crease)(self.raw(), flat.as_ptr(), edges.len() as u32, on) },
            "subd_set_crease",
        )
    }

    /// A new cage with `vertices` pinned (they refine as corners and stay put), or released
    /// when `on` is false; it selects them.
    pub fn pin(&self, vertices: &[u32], on: bool) -> Result<Subd> {
        self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_set_pin)(self.raw(), vertices.as_ptr(), vertices.len() as u32, on) },
            "subd_set_pin",
        )
    }

    /// A new cage with `faces` pushed out by `distance` along each connected region's average
    /// normal, a quad wall on each boundary edge; the moved faces keep their ids and the new
    /// cage selects them.
    pub fn extrude(&self, faces: &[u32], distance: f64) -> Result<Subd> {
        self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_extrude)(self.raw(), faces.as_ptr(), faces.len() as u32, distance) },
            "subd_extrude",
        )
    }

    /// A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface and a ring
    /// of quads round each region (each face, with `individual`); the new cage selects the
    /// inner faces.
    pub fn inset(&self, faces: &[u32], amount: f64, individual: bool) -> Result<Subd> {
        self.edit(
            unsafe {
                (self.api.cadaclysm_blacksmith_subd_inset)(self.raw(), faces.as_ptr(), faces.len() as u32, amount, individual)
            },
            "subd_inset",
        )
    }

    /// A new cage with a loop of edges cut across the ring of quads through `edge`, at
    /// `a + at * (b - a)` with `at` in (0, 1) (0.5 is the middle); it selects the new loop.
    pub fn insert_loop(&self, edge: (u32, u32), at: f64) -> Result<Subd> {
        self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_insert_loop)(self.raw(), edge.0, edge.1, at) },
            "subd_insert_loop",
        )
    }

    /// The loop of edges through `edge`, straight across each valence-four vertex, the picked
    /// edge first, each pair smaller id first; empty when `edge` is not an edge of the cage.
    pub fn edge_loop(&self, edge: (u32, u32)) -> Result<Vec<(u32, u32)>> {
        // The kernel answers with a cage whose selection is the loop; it drops (is freed) on
        // every path out of here, the empty loop's too.
        let looped = self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_edge_loop)(self.raw(), edge.0, edge.1) },
            "subd_edge_loop",
        )?;
        Ok(match looped.selection()? {
            Some(SubdSelection::Edges(edges)) => edges,
            _ => Vec::new(),
        })
    }

    /// The positive half of the cage across the plane perpendicular to `axis`, as a mirrored
    /// cage: every later edit keeps it symmetric.
    pub fn mirror_on(&self, axis: SubdAxis) -> Result<Subd> {
        self.edit(unsafe { (self.api.cadaclysm_blacksmith_subd_mirror_on)(self.raw(), axis.code()) }, "subd_mirror_on")
    }

    /// The mirror baked: the whole cage as an ordinary one, no longer mirrored.
    pub fn mirror_off(&self) -> Result<Subd> {
        self.edit(unsafe { (self.api.cadaclysm_blacksmith_subd_mirror_off)(self.raw()) }, "subd_mirror_off")
    }

    /// The whole cage of a mirrored half -- the half's vertices first, then the reflections of
    /// those off the plane -- or a copy of an ordinary cage.
    pub fn full(&self) -> Result<Subd> {
        self.edit(unsafe { (self.api.cadaclysm_blacksmith_subd_full)(self.raw()) }, "subd_full")
    }

    /// The smooth surface refined `levels` times (1 to 6; the other wrappers default to 3),
    /// as a [`SubdMesh`] of copies.
    pub fn smooth_mesh(&self, levels: u32) -> Result<SubdMesh> {
        let mut out = sys::CadaclysmBlacksmithSubdMesh::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_subd_smooth_mesh)(self.raw(), levels, &mut out) } {
            return Err(fail(self.api, "subd_smooth_mesh"));
        }
        let (n, m) = (out.vertex_count as usize, out.index_count as usize / 3);
        let triples = |flat: Vec<f64>| -> Vec<[f64; 3]> { flat.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect() };
        let ids: Vec<u32> = unsafe { copied(out.indices, 3 * m) };
        Ok(SubdMesh {
            positions: triples(unsafe { copied(out.positions, 3 * n) }),
            normals: triples(unsafe { copied(out.normals, 3 * n) }),
            indices: ids.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
            triangle_face: unsafe { copied(out.triangle_face, m) },
        })
    }

    /// The cage element of `kind` under `point`, a point on or near the smooth surface: a
    /// one-element [`SubdSelection`] (an edge as its vertex pair, smaller id first). `None`
    /// when nothing is within 0.05 of the cage's diagonal -- not an error; a refusal (a
    /// point that is not finite) is.
    pub fn pick(&self, point: [f64; 3], kind: SubdElements) -> Result<Option<SubdSelection>> {
        let mut out = [0u32; 2];
        if !unsafe { (self.api.cadaclysm_blacksmith_subd_pick)(self.raw(), point.as_ptr(), kind.code(), out.as_mut_ptr()) } {
            // Nothing near leaves an empty `last_error`; a refusal never does.
            return if failed(self.api) { Err(fail(self.api, "subd_pick")) } else { Ok(None) };
        }
        Ok(Some(match kind {
            SubdElements::Vertices => SubdSelection::Vertices(vec![out[0]]),
            SubdElements::Edges => SubdSelection::Edges(vec![(out[0], out[1])]),
            SubdElements::Faces => SubdSelection::Faces(vec![out[0]]),
        }))
    }

    /// The cage as an exact solid, one NURBS face per patch, that every solid call takes,
    /// and a [`SubdReport`] of what the conversion did. A cage that cannot be held within
    /// `options` is refused with the figures it measured.
    pub fn to_solid(&self, options: SubdSolidOptions) -> Result<(Solid, SubdReport)> {
        let mut report = sys::CadaclysmBlacksmithSubdReport::default();
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_subd_to_solid)(self.raw(), options.tolerance, options.g1_angle, options.max_levels, &mut report)
        };
        Ok((Solid::wrap(self.api, raw, "subd_to_solid")?, report.into()))
    }
}

// ---- assemblies -------------------------------------------------------------------

/// A mutable tree of placements: a name, and zero or more solids or other assemblies
/// placed in it at a frame. `place_solid`/`place_assembly` return the placement's name so
/// a caller can keep it. Unlike [`Solid`], placing shares rather than copies -- placing
/// one assembly under another does not snapshot it, so a later placement on the shared
/// one shows up wherever it already sits (see [`place_assembly`](Assembly::place_assembly)'s
/// own note on cycles). Dropping one frees this handle; it does **not** free what was
/// placed in it if that is still reachable from somewhere else.
///
/// `Send` but not `Sync`, as [`Path`]: the kernel's own `PLACING` lock makes one `place`
/// call at a time safe from any thread, but nothing makes two threads placing into the
/// same assembly *at once* safe together, so this crate does not claim it either.
pub struct Assembly {
    handle: NonNull<sys::CadaclysmBlacksmithAssembly>,
    api: &'static Api,
}

unsafe impl Send for Assembly {}

impl Drop for Assembly {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_assembly_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Assembly {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Assembly({:p})", self.handle)
    }
}

/// [`Assembly::pair`]'s optional arguments -- Rust's spelling of Python's keyword
/// arguments. `end_frame` `None` is "the pair's rest frame itself" (all-zero rest
/// values); `ranges` `None` is "no ranges given" (a kind that allows none, or every
/// freedom left unbounded by omission); within `ranges`, each side `None` is that side
/// unbounded. `pitch` `None` is NaN -- required and non-zero for `"screw"`, refused for
/// any other kind. [`pair_freedom_count`] sizes `ranges`: one entry per freedom of
/// `kind`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PairOptions {
    pub end_frame: Option<Frame>,
    pub ranges: Option<Vec<(Option<f64>, Option<f64>)>>,
    pub pitch: Option<f64>,
}

/// What `pair_raw` hands the C ABI last: a pitch (`cadaclysm_blacksmith_assembly_pair`) or a
/// parameter list (`..._pair_with`).
enum PairArg<'a> {
    Pitch(f64),
    Params(&'a [f64]),
}

impl Assembly {
    /// The raw pointer every call takes -- `*mut`, since `place_solid`, `place_assembly`
    /// and `Drop` all mutate through it; a call that only reads (`name`, `step_text`)
    /// passes it where a `*const` is asked for, which a `*mut` coerces to.
    fn raw(&self) -> *mut sys::CadaclysmBlacksmithAssembly {
        self.handle.as_ptr()
    }

    /// A new, empty assembly called `name`. Refused for an empty name.
    pub fn new(name: &str) -> Result<Assembly> {
        let api = api()?;
        let cname = c_text("name", name)?;
        let raw = unsafe { (api.cadaclysm_blacksmith_assembly_new)(cname.as_ptr()) };
        NonNull::new(raw).map(|handle| Assembly { handle, api }).ok_or_else(|| fail(api, "assembly_new"))
    }

    /// Free it now rather than at the end of scope.
    pub fn close(self) {}

    /// This assembly's own name, given when it was made.
    pub fn name(&self) -> String {
        unsafe { text((self.api.cadaclysm_blacksmith_assembly_name)(self.raw())) }
    }

    /// Place `s` at `frame` (must be right-handed and orthonormal) in this assembly,
    /// called `name` -- or, with `name` `None`, `s`'s own name ([`Solid::name`], `"part"`
    /// for an unnamed one), numbered past any already taken here (`"bolt"`, `"bolt 2"`,
    /// ...). An explicit `name` already taken here is refused. Returns the placement's
    /// name -- Python's `place`, split as this crate has no type-dispatching overload;
    /// see [`place_assembly`](Self::place_assembly) for placing another assembly.
    pub fn place_solid(&self, s: &Solid, frame: &Frame, name: Option<&str>) -> Result<String> {
        let cname = name.map(|n| c_text("name", n)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_place_solid)(
                self.raw(),
                s.raw(),
                frame.v.as_ptr(),
                cname.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            )
        };
        place_result(self.api, raw, "assembly_place_solid")
    }

    /// As [`place_solid`](Self::place_solid), but placing another assembly, `placed`,
    /// rather than a solid -- sharing it, not copying it, so a later placement on
    /// `placed` (through this assembly or another) shows up wherever it is placed.
    /// Placing `placed` as this assembly itself, or anywhere above this assembly in the
    /// tree already, is refused, naming the cycle, since writing that out would never
    /// terminate.
    pub fn place_assembly(&self, placed: &Assembly, frame: &Frame, name: Option<&str>) -> Result<String> {
        let cname = name.map(|n| c_text("name", n)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_place_assembly)(
                self.raw(),
                placed.raw(),
                frame.v.as_ptr(),
                cname.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            )
        };
        place_result(self.api, raw, "assembly_place_assembly")
    }

    /// Declare a rigid link called `name` over `placements` -- names of placements of this
    /// assembly itself, not of assemblies placed in it. An empty name, a name already taken
    /// by a link here, no placements, a placement named twice, one this assembly does not
    /// have, or one already in another link is refused and leaves the assembly as it was.
    /// Written as an AP242 kinematic link; a mechanism anywhere in the tree makes AP242 the
    /// default schema of [`step_text`](Self::step_text).
    pub fn link(&self, name: &str, placements: &[&str]) -> Result<()> {
        let name = c_text("name", name)?;
        let owned: Vec<CString> = placements.iter().map(|p| c_text("placement", p)).collect::<Result<_>>()?;
        let ptrs: Vec<*const c_char> = owned.iter().map(|s| s.as_ptr()).collect();
        let ptr = if ptrs.is_empty() { ptr::null() } else { ptrs.as_ptr() };
        if unsafe { (self.api.cadaclysm_blacksmith_assembly_link)(self.raw(), name.as_ptr(), ptr, ptrs.len()) } {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_link"))
        }
    }

    /// Connect this assembly's links `start` and `end`, kept in that order, as a joint
    /// called `name`. An empty name, a name taken by another joint here, a link this
    /// assembly does not have, a link joined to itself, or a (start, end) pair already
    /// joined is refused; the reverse pair is a different joint.
    pub fn joint(&self, name: &str, start: &str, end: &str) -> Result<()> {
        let name = c_text("name", name)?;
        let start = c_text("start", start)?;
        let end = c_text("end", end)?;
        if unsafe { (self.api.cadaclysm_blacksmith_assembly_joint)(self.raw(), name.as_ptr(), start.as_ptr(), end.as_ptr()) } {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_joint"))
        }
    }

    /// Gives joint `joint` its pair: `kind` (a name of the kind table -- `"revolute"`,
    /// `"prismatic"`, `"cylindrical"`, `"screw"`, `"spherical"`, `"spherical_with_pin"`,
    /// `"planar"`, `"universal"`, `"homokinetic"`, `"fully_constrained"` or
    /// `"unconstrained"`), the contact frame at rest, and `options` -- see
    /// [`PairOptions`]. An unknown or already-paired joint, an unknown kind, a bad pitch,
    /// ranges given where none are allowed or of the wrong length, a non-finite or
    /// inverted range, or an end frame this kind's motion cannot reach is refused; the
    /// assembly is then unchanged.
    pub fn pair(&self, joint: &str, kind: &str, frame: &Frame, options: &PairOptions) -> Result<()> {
        let pitch = options.pitch.unwrap_or(f64::NAN);
        self.pair_raw(joint, kind, frame, options, PairArg::Pitch(pitch))
    }

    fn pair_raw(&self, joint: &str, kind: &str, frame: &Frame, options: &PairOptions, arg: PairArg<'_>) -> Result<()> {
        let joint_c = c_text("joint", joint)?;
        let kind_c = c_text("kind", kind)?;
        let end_frame = options.end_frame.as_ref().map(|f| f.v);
        // `ranges` being `Some(..)` -- even `Some(vec![])` -- means ranges were GIVEN, and
        // the C ABI must see non-null pointers with the given count (possibly 0), never
        // "no ranges" (all four pointers null, which only `None` means). A `Vec`'s pointer
        // is always non-null (dangling-but-valid when empty), so no extra buffer is needed.
        let ranges_given = options.ranges.is_some();
        let (lower, upper, has_lower, has_upper, freedom_count) = match &options.ranges {
            None => (Vec::new(), Vec::new(), Vec::new(), Vec::new(), 0usize),
            Some(ranges) => {
                let mut lower = Vec::with_capacity(ranges.len());
                let mut upper = Vec::with_capacity(ranges.len());
                let mut has_lower = Vec::with_capacity(ranges.len());
                let mut has_upper = Vec::with_capacity(ranges.len());
                for (lo, hi) in ranges {
                    lower.push(lo.unwrap_or(0.0));
                    upper.push(hi.unwrap_or(0.0));
                    has_lower.push(lo.is_some());
                    has_upper.push(hi.is_some());
                }
                (lower, upper, has_lower, has_upper, ranges.len())
            }
        };
        let ok = unsafe {
            match arg {
            PairArg::Pitch(pitch) => (self.api.cadaclysm_blacksmith_assembly_pair)(
                self.raw(),
                joint_c.as_ptr(),
                kind_c.as_ptr(),
                frame.v.as_ptr(),
                end_frame.as_ref().map_or(ptr::null(), |f| f.as_ptr()),
                if ranges_given { lower.as_ptr() } else { ptr::null() },
                if ranges_given { upper.as_ptr() } else { ptr::null() },
                if ranges_given { has_lower.as_ptr() } else { ptr::null() },
                if ranges_given { has_upper.as_ptr() } else { ptr::null() },
                freedom_count,
                pitch,
            ),
            PairArg::Params(params) => (self.api.cadaclysm_blacksmith_assembly_pair_with)(
                self.raw(),
                joint_c.as_ptr(),
                kind_c.as_ptr(),
                frame.v.as_ptr(),
                end_frame.as_ref().map_or(ptr::null(), |f| f.as_ptr()),
                if ranges_given { lower.as_ptr() } else { ptr::null() },
                if ranges_given { upper.as_ptr() } else { ptr::null() },
                if ranges_given { has_lower.as_ptr() } else { ptr::null() },
                if ranges_given { has_upper.as_ptr() } else { ptr::null() },
                freedom_count,
                params.as_ptr(),
                params.len(),
            ),
            }
        };
        if ok {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_pair"))
        }
    }

    /// [`pair`](Self::pair) with the kind's own numbers as a list instead of a pitch:
    /// `"screw"` `[pitch]`; `"rack_and_pinion"` `[pinion_radius]`; `"gear"`
    /// `[radius_first, radius_second, ratio]` or plus `[bevel, helical_angle]` (radians),
    /// `ratio` the second link's rotation over the first's, signed; none for any other
    /// kind. A wrong count is refused (`pair: a gear takes 3 or 5 parameters, not 2`);
    /// `options.pitch` is ignored. Everything else is [`pair`](Self::pair)'s.
    pub fn pair_with(&self, joint: &str, kind: &str, frame: &Frame, options: &PairOptions, params: &[f64]) -> Result<()> {
        self.pair_raw(joint, kind, frame, options, PairArg::Params(params))
    }

    /// Adds a named state: `rows` sets each named joint to its values, in that joint's
    /// pair's freedom order. An empty or duplicate name, no rows, an unknown joint, a
    /// joint set twice, a joint with no pair or none of its pair's freedoms, a row of the
    /// wrong length, or a non-finite or out-of-range value is refused; the assembly is
    /// then unchanged.
    pub fn state(&self, name: &str, rows: &[(&str, &[f64])]) -> Result<()> {
        let name_c = c_text("name", name)?;
        let joints: Vec<CString> = rows.iter().map(|(j, _)| c_text("joint", j)).collect::<Result<_>>()?;
        let joint_ptrs: Vec<*const c_char> = joints.iter().map(|c| c.as_ptr()).collect();
        let counts: Vec<u32> = rows.iter().map(|(_, v)| v.len() as u32).collect();
        let flat: Vec<f64> = rows.iter().flat_map(|(_, v)| v.iter().copied()).collect();
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_state)(
                self.raw(),
                name_c.as_ptr(),
                if joint_ptrs.is_empty() { ptr::null() } else { joint_ptrs.as_ptr() },
                if counts.is_empty() { ptr::null() } else { counts.as_ptr() },
                if flat.is_empty() { ptr::null() } else { flat.as_ptr() },
                rows.len(),
            )
        };
        if ok {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_state"))
        }
    }

    /// This assembly with its mechanism posed, as a new [`Assembly`] (this one is
    /// unchanged either way). `rows` sets each joint to its values, in that joint's pair's
    /// freedom order (radians, the assembly's units): a joint is a path of placement
    /// names then the joint's name, joined by "/" (a "/" or "\\" inside a name escaped
    /// with "\\"). `state` is a state's path, applied first and overridden row by row;
    /// `ground` is one of this assembly's own links, held fixed. No rows is allowed. A
    /// sub-assembly no row reaches is shared with this one. A name that matches several
    /// joints, an unknown joint or state, or an out-of-range value is refused with the
    /// kernel's own text (`posed: value 0 of joint 'shoulder' is 2, outside its range`).
    pub fn posed(&self, rows: &[(&str, &[f64])], state: Option<&str>, ground: Option<&str>) -> Result<Assembly> {
        let joints: Vec<CString> = rows.iter().map(|(j, _)| c_text("joint", j)).collect::<Result<_>>()?;
        let joint_ptrs: Vec<*const c_char> = joints.iter().map(|c| c.as_ptr()).collect();
        let counts: Vec<u32> = rows.iter().map(|(_, v)| v.len() as u32).collect();
        let flat: Vec<f64> = rows.iter().flat_map(|(_, v)| v.iter().copied()).collect();
        let state_c = state.map(|s| c_text("state", s)).transpose()?;
        let ground_c = ground.map(|g| c_text("ground", g)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_posed)(
                self.raw(),
                if joint_ptrs.is_empty() { ptr::null() } else { joint_ptrs.as_ptr() },
                if counts.is_empty() { ptr::null() } else { counts.as_ptr() },
                if flat.is_empty() { ptr::null() } else { flat.as_ptr() },
                rows.len(),
                state_c.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
                ground_c.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            )
        };
        NonNull::new(raw).map(|handle| Assembly { handle, api: self.api }).ok_or_else(|| fail(self.api, "assembly_posed"))
    }

    /// Adds a named motion sequence: each segment is `(state name, t, interpolation word)`,
    /// the word one of `"undefined"`, `"discontinuous"`, `"synchronous"` or `"linear"`. The
    /// sequence is closed unless its last segment is `"discontinuous"`; `seconds` says its
    /// parameter is in seconds. An empty or duplicate name, fewer than two segments, an
    /// unknown state, a non-finite or decreasing parameter or an unknown word is refused;
    /// the assembly is then unchanged.
    pub fn sequence(&self, name: &str, segments: &[(&str, f64, &str)], seconds: bool) -> Result<()> {
        let name_c = c_text("name", name)?;
        let states: Vec<CString> = segments.iter().map(|(s, _, _)| c_text("state", s)).collect::<Result<_>>()?;
        let words: Vec<CString> = segments.iter().map(|(_, _, w)| c_text("interpolation", w)).collect::<Result<_>>()?;
        let state_ptrs: Vec<*const c_char> = states.iter().map(|c| c.as_ptr()).collect();
        let word_ptrs: Vec<*const c_char> = words.iter().map(|c| c.as_ptr()).collect();
        let ts: Vec<f64> = segments.iter().map(|(_, t, _)| *t).collect();
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_sequence)(
                self.raw(),
                name_c.as_ptr(),
                if state_ptrs.is_empty() { ptr::null() } else { state_ptrs.as_ptr() },
                if ts.is_empty() { ptr::null() } else { ts.as_ptr() },
                if word_ptrs.is_empty() { ptr::null() } else { word_ptrs.as_ptr() },
                segments.len(),
                seconds,
            )
        };
        if ok {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_sequence"))
        }
    }

    /// Declares this assembly's base link. `link` naming no link of this assembly, or a
    /// base already declared, is refused, naming the link already there.
    pub fn base(&self, link: &str) -> Result<()> {
        let link = c_text("link", link)?;
        if unsafe { (self.api.cadaclysm_blacksmith_assembly_base)(self.raw(), link.as_ptr()) } {
            Ok(())
        } else {
            Err(fail(self.api, "assembly_base"))
        }
    }

    /// This assembly, and everything placed under it, as one STEP file: this assembly
    /// the root product, each sub-assembly and each distinct part written once, each
    /// placement an occurrence named as it was placed. `schema` and `unit` as
    /// [`Solid::step_text`]. Refused if this assembly, or a sub-assembly reachable from
    /// it, places nothing -- a reader would never show it.
    pub fn step_text(&self, schema: Option<&str>, unit: Unit) -> Result<String> {
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
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_step)(self.raw(), schema.as_ref().map_or(ptr::null(), |s| s.as_ptr()), unit as u32)
        };
        if raw.is_null() {
            return Err(fail(self.api, "assembly_step"));
        }
        let out = unsafe { text(raw as *const c_char) };
        unsafe { (self.api.cadaclysm_blacksmith_string_free)(raw) };
        Ok(out)
    }

    /// This assembly written to a STEP file at `path`.
    pub fn step(&self, path: impl AsRef<FsPath>, schema: Option<&str>, unit: Unit) -> Result<()> {
        let path = path.as_ref();
        let text = self.step_text(schema, unit)?;
        std::fs::write(path, text).map_err(|e| Error::new(format!("{}: {e}", path.display())))
    }

    /// This assembly as a reader [`Scene`], through STEP text -- see
    /// [`Solid::to_scene`].
    pub fn to_scene(&self, schema: Option<&str>) -> Result<Scene> {
        let text = self.step_text(schema, Unit::Millimetre)?;
        let mut options = OpenOptions::new();
        if let Some(file) = schema.and_then(schema_file) {
            options = options.schema(file);
        }
        options.open_memory(text.as_bytes(), "stp")
    }
}

/// How many freedoms a pair kind has, so a caller can size [`PairOptions::ranges`]: one
/// entry per freedom of `kind`. 0 for an unknown name, for `"fully_constrained"` (which
/// has none), and if the kernel library cannot be loaded.
pub fn pair_freedom_count(kind: &str) -> u32 {
    let Ok(api) = api() else { return 0 };
    let Ok(kind) = c_text("kind", kind) else { return 0 };
    unsafe { (api.cadaclysm_blacksmith_pair_freedom_count)(kind.as_ptr()) }
}

/// The owned text `place_solid`/`place_assembly` return -- the placement's name -- read
/// out and freed; null and `last_error` on a refusal.
fn place_result(api: &'static Api, raw: *mut c_char, what: &str) -> Result<String> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let out = unsafe { text(raw) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(raw) };
    Ok(out)
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

// ---- the FEM surface mesh ---------------------------------------------------------

/// One B-rep edge of a kernel FEM mesh: the chain of nodes along it, and where that chain
/// breaks. The kernel's twin of [`crate::FemEdge`], field for field -- a separate type
/// because this is a separate ABI whose header may move on its own, and because `faces`
/// numbers *this* solid's faces.
///
/// `nodes` and `runs` are borrowed from the [`FemMesh`] they came from; `runs` says where
/// the chain breaks, and [`FemEdge::chains`] does that walk. `faces` is
/// `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of each [`NONE`] where
/// there is none -- an open sheet's rim, or both ends at one vertex. **`0` is a real face
/// and a real vertex, not a sentinel.**
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FemEdge<'m> {
    /// The **solid's own** edge id, not this mesh's edge index: [`FemMesh::edges`] is a
    /// densely renumbered subset of the solid's edges with every edge collapsed to a point
    /// left out, so a sphere -- whose two pole runs collapse -- reports its seam as edge 0
    /// with an id of 1. Everything else here that names an edge means the index. It is not
    /// a row of [`Solid::edges`] either: that table is the solid's edges grouped by
    /// geometry, where this id names the topological edge the `.msh` entities and the
    /// censuses speak in.
    pub id: u32,
    pub nodes: &'m [u32],
    /// Where each connected run of `nodes` begins; `[0]` for one chain along the edge.
    pub runs: &'m [u32],
    /// `(face_a, face_b)`, numbering the solid's faces as [`Solid::face_kind`] does; the
    /// second is [`NONE`] on an open sheet's rim.
    pub faces: (u32, u32),
    /// `(end_a, end_b)`, the second [`NONE`] where both ends are one vertex.
    pub ends: (u32, u32),
    /// The nodes make one loop. Never true where there is more than one run.
    pub closed: bool,
    /// Bounded twice by one face: a closed surface's seam. Both `faces` are then that face.
    pub seam: bool,
}

impl<'m> FemEdge<'m> {
    /// # Safety
    /// `raw`'s `nodes` and `runs` must be null or point at their counts' worth of `u32`s
    /// living for `'m`, which they do for as long as the [`FemMesh`] does.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithFemEdge) -> FemEdge<'m> {
        unsafe {
            FemEdge {
                id: raw.id,
                nodes: borrowed(raw.nodes, raw.node_count as usize),
                runs: borrowed(raw.runs, raw.run_count as usize),
                faces: (raw.face_a, raw.face_b),
                ends: (raw.end_a, raw.end_b),
                closed: raw.closed,
                seam: raw.seam,
            }
        }
    }

    /// Each connected run of `nodes` as its own polyline, in order along the edge: what
    /// `runs` is for, and the only safe way to read the chain. One item is the ordinary
    /// answer; join nothing across a boundary.
    pub fn chains(&self) -> impl Iterator<Item = &'m [u32]> + '_ {
        let nodes = self.nodes;
        (0..self.runs.len()).map(move |i| {
            let start = (self.runs[i] as usize).min(nodes.len());
            let end = self.runs.get(i + 1).map_or(nodes.len(), |&r| (r as usize).min(nodes.len()));
            &nodes[start..start.max(end)]
        })
    }
}

/// One B-rep vertex of a kernel FEM mesh: the kernel's twin of [`crate::FemVertex`]. Plain
/// data, all of it copied out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FemVertex {
    /// The mesh node at this vertex, or [`NONE`] where the mesh has none there -- **which
    /// is ordinary, not a fault**: the analysis rebuilds a vertex wherever two trims meet,
    /// so a sphere has 48 of them where the mesh has two points.
    pub node: u32,
    /// Where the vertex is, in the same space and under the same placement as
    /// [`FemMesh::nodes`]. **Meaningless unless `has_position`**: zeroed then, a point no
    /// geometry has and one a solver would read as a node at the origin.
    pub point: [f64; 3],
    pub has_position: bool,
}

impl FemVertex {
    fn from_raw(raw: &sys::CadaclysmBlacksmithFemVertex) -> FemVertex {
        FemVertex { node: raw.node, point: raw.point, has_position: raw.has_position }
    }
}

/// One solid meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack reported
/// rather than closed. What [`Solid::fem_mesh`] returns.
///
/// **An owned handle, and it owns everything it lends.** Freed when dropped, or by
/// [`FemMesh::free`]; it borrows nothing from the [`Solid`] it was built from, so
/// [`Solid::close`] does not free it and meshing the solid again at another tolerance does
/// not stale it -- unlike [`Solid::mesh`], whose slices come out of the cache that replaces.
/// That is why [`Solid::fem_mesh`] takes `&self` where `Solid::mesh` takes `&mut self`.
///
/// Its five flat arrays are slices of the library's own memory borrowed from `&self`. Every
/// other wrapper needs a run-time guard against a view read after the handle is freed, and
/// none of them can guard a view *already in hand*; this one cannot compile:
///
/// ```compile_fail,E0505
/// # use cadaclysm_sdk::blacksmith::Solid;
/// # fn main() -> cadaclysm_sdk::Result<()> {
/// let solid = Solid::cuboid(1.0, 1.0, 1.0)?;
/// let mesh = solid.fem_mesh(0.05, 0.0, None)?;
/// let nodes = mesh.nodes();
/// mesh.free(); // error: `mesh` is still borrowed by `nodes`
/// let _ = nodes.len();
/// # Ok(())
/// # }
/// ```
///
/// **That block is documentation, not an assertion**, as its reader-library twin's own note
/// says: `compile_fail` asks only that the snippet fail to compile and rustdoc never checks
/// *what* failed. [`FemMesh::free`] taking the mesh by value is what makes the claim true.
pub struct FemMesh {
    handle: NonNull<sys::CadaclysmBlacksmithFemMesh>,
    api: &'static Api,
    /// Read once when the handle is made: every pointer in it is built with the handle and
    /// never moves, so asking again per accessor would be one C call for the same answer.
    view: sys::CadaclysmBlacksmithFemMeshView,
}

// The handle is owned outright and every accessor takes a `const` pointer, so it may move
// to another thread. Not `Sync`, as a `Solid` is not: the conservative half of the same
// rule, and nothing in this crate needs two threads reading one FEM mesh.
unsafe impl Send for FemMesh {}

impl FemMesh {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithFemMesh) -> Result<FemMesh> {
        let handle = NonNull::new(raw).ok_or_else(|| fail(api, "fem_mesh"))?;
        let mut view = std::mem::MaybeUninit::<sys::CadaclysmBlacksmithFemMeshView>::uninit();
        if !unsafe { (api.cadaclysm_blacksmith_fem_mesh_view)(handle.as_ptr(), view.as_mut_ptr()) } {
            let why = fail(api, "fem_mesh_view");
            unsafe { (api.cadaclysm_blacksmith_fem_mesh_free)(handle.as_ptr()) };
            return Err(why);
        }
        // SAFETY: the call returned true, so it wrote the whole struct.
        Ok(FemMesh { handle, api, view: unsafe { view.assume_init() } })
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithFemMesh {
        self.handle.as_ptr()
    }

    // -- the flat arrays, borrowed from the handle

    /// Every node's position: placed by [`Solid::fem_mesh`]'s placement, in the solid's own
    /// coordinates otherwise.
    pub fn nodes(&self) -> &[[f64; 3]] {
        // SAFETY: the pointers were built with the handle and live until it is freed,
        // which `&self` rules out for the life of the slice.
        unsafe { groups64::<3>(self.view.nodes, self.view.node_count as usize).unwrap_or(&[]) }
    }

    /// Three node indices a triangle, wound outward -- a mirroring placement is wound back.
    pub fn triangles(&self) -> &[[u32; 3]] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.triangles.cast::<[u32; 3]>(), self.view.triangle_count as usize) }
    }

    /// Which face each triangle lies on, one per triangle: the same faces
    /// [`Solid::face_kind`] names.
    pub fn triangle_face(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.triangle_face, self.view.triangle_count as usize) }
    }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, the `.msh` format's own rule.
    /// [`FemMesh::node_entity`] says which entity of that kind.
    pub fn node_kind(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.node_kind, self.view.node_count as usize) }
    }

    /// Which vertex, edge or face each node lies on, read by the matching
    /// [`FemMesh::node_kind`]: an index into [`FemMesh::vertices`], into
    /// [`FemMesh::edges`], or into the solid's faces.
    pub fn node_entity(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.node_entity, self.view.node_count as usize) }
    }

    // -- the topology

    /// The solid's faces -- the same faces [`Solid::faces`] counts.
    pub fn face_count(&self) -> u32 {
        self.view.face_count
    }

    /// One [`FemEdge`] per B-rep edge, in the order a [`FemMesh::node_kind`] of `1` indexes
    /// them. **Not [`Solid::edges`]' numbering**: these are the manifold analysis's,
    /// ascending by edge id.
    pub fn edges(&self) -> Result<Vec<FemEdge<'_>>> {
        (0..self.view.edge_count)
            .map(|i| {
                let mut raw = std::mem::MaybeUninit::<sys::CadaclysmBlacksmithFemEdge>::uninit();
                if !unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_edge)(self.raw(), i, raw.as_mut_ptr()) } {
                    return Err(fail(self.api, "fem_mesh_edge"));
                }
                // SAFETY: the call returned true, so it wrote the whole struct; its two
                // pointers belong to the handle, which `&self` holds for `'_`.
                Ok(unsafe { FemEdge::from_raw(&raw.assume_init()) })
            })
            .collect()
    }

    /// One [`FemVertex`] per B-rep vertex, in the order a [`FemMesh::node_kind`] of `0`
    /// indexes them.
    pub fn vertices(&self) -> Result<Vec<FemVertex>> {
        (0..self.view.vertex_count)
            .map(|i| {
                let mut raw = std::mem::MaybeUninit::<sys::CadaclysmBlacksmithFemVertex>::uninit();
                if !unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_vertex)(self.raw(), i, raw.as_mut_ptr()) } {
                    return Err(fail(self.api, "fem_mesh_vertex"));
                }
                // SAFETY: the call returned true, so it wrote the whole struct.
                Ok(FemVertex::from_raw(&unsafe { raw.assume_init() }))
            })
            .collect()
    }

    // -- the crack census

    /// Every crack, as `(a, b, brep_edge)`: a directed mesh edge `(a, b)` with no `(b, a)`,
    /// and the B-rep edge both nodes lie on or [`NONE`] where they share none.
    ///
    /// **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked
    /// about at all: an open sheet reports [`FemMesh::watertight`] false with this and
    /// [`FemMesh::folded_edges`] both empty, and *that trio together* says "not asked",
    /// not "nothing found". A sheet's rim is not a crack.
    pub fn open_edges(&self) -> Result<Vec<(u32, u32, u32)>> {
        self.census(self.api.cadaclysm_blacksmith_fem_mesh_open_edge, self.view.open_edge_count, "fem_mesh_open_edge")
    }

    /// Every fold, as [`FemMesh::open_edges`] reports a crack: a directed mesh edge used by
    /// more than one triangle.
    ///
    /// **A solid can be folded without being open** -- one no thicker than a line leaves no
    /// hole for an open edge to find -- and the closure census's own known-bad bodies are
    /// folds rather than open cracks. A caller that checks [`FemMesh::open_edges`] alone
    /// calls such a body sound.
    pub fn folded_edges(&self) -> Result<Vec<(u32, u32, u32)>> {
        self.census(self.api.cadaclysm_blacksmith_fem_mesh_folded_edge, self.view.folded_edge_count, "fem_mesh_folded_edge")
    }

    /// One flattened census, row by row: the shape both censuses share, so they cannot
    /// drift.
    fn census(
        &self,
        call: unsafe extern "C" fn(*const sys::CadaclysmBlacksmithFemMesh, u32, *mut u32, *mut u32, *mut u32) -> bool,
        count: u32,
        what: &str,
    ) -> Result<Vec<(u32, u32, u32)>> {
        (0..count)
            .map(|i| {
                let (mut a, mut b, mut edge) = (0u32, 0u32, 0u32);
                if !unsafe { call(self.raw(), i, &mut a, &mut b, &mut edge) } {
                    return Err(fail(self.api, what));
                }
                Ok((a, b, edge))
            })
            .collect()
    }

    /// Every pair of triangles that pass through each other, as `(a, b)` with `a < b`,
    /// sorted: an edge of one through the other's interior. Their B-rep faces are
    /// [`FemMesh::triangle_face`]`[a]` and `[b]`.
    ///
    /// **Computed for every solid, open or closed.** The census [`FemMesh::watertight`],
    /// [`FemMesh::open_edges`] and [`FemMesh::folded_edges`] report is topological and
    /// cannot see a surface passing through itself; a mesh is ready for a volume mesher
    /// when it is [`FemMesh::watertight`] **and** this is empty -- Gmsh refuses one that
    /// crosses. A copy.
    pub fn crossings(&self) -> Result<Vec<(u32, u32)>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_crossing_count)(self.raw()) };
        (0..count)
            .map(|i| {
                let (mut a, mut b) = (0u32, 0u32);
                if !unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_crossing)(self.raw(), i, &mut a, &mut b) } {
                    return Err(fail(self.api, "fem_mesh_crossing"));
                }
                Ok((a, b))
            })
            .collect()
    }

    // -- the summary

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none
    /// used twice -- and so does the topology behind it. **False for every solid whose
    /// topology is not closed**, whose mesh is then not asked about; read
    /// [`FemMesh::open_edges`] for what an empty census beside a false here means.
    pub fn watertight(&self) -> bool {
        self.view.watertight
    }

    /// Always false here: the kernel has no mesh fallback, every FEM mesh coming off an
    /// exact B-rep. The reader library's [`crate::FemMesh::from_mesh`] is where this is the
    /// flag that says which of two spaces -- and which of two census contracts -- a caller
    /// is holding, and it is carried across so one FEM mesh reads the same on both sides.
    pub fn from_mesh(&self) -> bool {
        self.view.from_mesh
    }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a
    /// solid that meshed to no triangles is a refusal, not a mesh.
    pub fn min_angle(&self) -> f64 {
        self.view.min_angle
    }

    /// The triangle with that angle, as an index into [`FemMesh::triangles`].
    pub fn worst_triangle(&self) -> u32 {
        self.view.worst_triangle
    }

    /// The longest triangle edge, placed. **The figure to check against
    /// [`Solid::fem_mesh`]'s `max_size`, and the only one that says what the mesh actually
    /// is**: `max_size` bounds the boundary segments and merely *targets* the interior --
    /// measured at 1.03x `max_size` on a face whose parameters run unevenly -- and one
    /// small enough beside the body to reach the mesher's own piece and station ceilings is
    /// not honoured at all.
    pub fn longest_edge(&self) -> f64 {
        self.view.longest_edge
    }

    // -- out

    /// The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a
    /// volume where the body closes, and a physical group naming each.
    ///
    /// **On this side of the ABI the library's text is owned by the caller**, and this
    /// releases it with `cadaclysm_blacksmith_string_free` before handing back a `String`
    /// -- as every other kernel writer here does. The reader library's
    /// [`crate::FemMesh::msh_text`] is the other way round: a borrowed slot on the handle,
    /// replaced by the next call on it and freed with the mesh. A reader porting one side's
    /// reasoning onto the other leaks or double-frees.
    ///
    /// **The unlicensed notice is printed here**, and on [`FemMesh::save_msh`] -- this
    /// library notices on its writers, where the reader library notices in
    /// [`crate::Node::fem_mesh`] and on neither `.msh` call. Each matches its own siblings.
    ///
    /// An error for a mesh the writer refuses, naming the field it cannot honour.
    pub fn msh_text(&self) -> Result<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_msh_text)(self.raw()) };
        if raw.is_null() {
            return Err(fail(self.api, "fem_mesh_msh_text"));
        }
        let owned = unsafe { text(raw as *const c_char) };
        unsafe { (self.api.cadaclysm_blacksmith_string_free)(raw) };
        Ok(owned)
    }

    /// [`FemMesh::msh_text`] written to `path` by the library itself: the same bytes from
    /// the same writer, straight to the file. An error for a mesh the writer refuses or a
    /// file it cannot write, naming the path. Notices as [`FemMesh::msh_text`] does.
    pub fn save_msh(&self, path: impl AsRef<FsPath>) -> Result<()> {
        let path = crate::c_path(path.as_ref())?;
        if !unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_save_msh)(self.raw(), path.as_ptr()) } {
            return Err(fail(self.api, "fem_mesh_save_msh"));
        }
        Ok(())
    }

    /// Give the mesh back now rather than at the end of scope, as [`Solid::close`] does.
    ///
    /// **It takes the mesh by value, so no view can survive it and it cannot run twice.**
    /// Every other wrapper needs "idempotent" and a freed guard because its `free` is a
    /// method on a handle a caller still holds; here the compiler takes the handle away.
    pub fn free(self) {}
}

impl Drop for FemMesh {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_fem_mesh_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for FemMesh {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "FemMesh(nodes={}, triangles={}, watertight={}, faces={})",
            self.view.node_count, self.view.triangle_count, self.view.watertight, self.view.face_count
        )
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

// ---- SAT --------------------------------------------------------------------------

/// One ACIS SAT file's text, each solid its own body: the analytic surfaces as their
/// own records, splines and swept surfaces as exact NURBS, in the layout Rhino's own
/// exporter writes. `unit` goes into the header as millimetres per unit.
pub fn write_sat_text(solids: &[&Solid], unit: Unit) -> Result<String> {
    let api = api()?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let raw = unsafe { (api.cadaclysm_blacksmith_sat_text)(handles.as_ptr(), handles.len(), unit as u32) };
    if raw.is_null() {
        return Err(fail(api, "sat_text"));
    }
    let text = unsafe { text(raw as *const c_char) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(raw) };
    Ok(text)
}

/// [`write_sat_text`] written to `path` by the library itself, which names the file in
/// its refusal when it cannot.
pub fn write_sat(path: impl AsRef<FsPath>, solids: &[&Solid], unit: Unit) -> Result<()> {
    let api = api()?;
    let path = crate::c_path(path.as_ref())?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let ok = unsafe { (api.cadaclysm_blacksmith_sat)(handles.as_ptr(), handles.len(), path.as_ptr(), unit as u32) };
    if ok { Ok(()) } else { Err(fail(api, "sat")) }
}

/// One OCCT `.brep` file's text, each solid its own solid under one compound (one
/// solid is the file's root): the exact surfaces and curves, with a curve in each
/// face's own parameters for every edge, so OCCT's `BRepTools::Read` gives a shape
/// `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep` carries none --
/// so the numbers are the numbers.
pub fn write_brep_text(solids: &[&Solid]) -> Result<String> {
    let api = api()?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let raw = unsafe { (api.cadaclysm_blacksmith_brep_text)(handles.as_ptr(), handles.len()) };
    if raw.is_null() {
        return Err(fail(api, "brep_text"));
    }
    let text = unsafe { text(raw as *const c_char) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(raw) };
    Ok(text)
}

/// [`write_brep_text`] written to `path` by the library itself.
pub fn write_brep(path: impl AsRef<FsPath>, solids: &[&Solid]) -> Result<()> {
    let api = api()?;
    let path = c_text("path", &path.as_ref().to_string_lossy())?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let ok = unsafe { (api.cadaclysm_blacksmith_brep)(handles.as_ptr(), handles.len(), path.as_ptr()) };
    if !ok {
        return Err(fail(api, "brep"));
    }
    Ok(())
}

// ---- SVG ----------------------------------------------------------------------------

/// A silhouette block the kernel handed over, freed when this drops. The kernel's
/// `..._free` needs the very `count` the call wrote, and the block carries no length of its own,
/// so the two travel together.
struct SilhouetteBlock {
    api: &'static Api,
    data: *mut f64,
    count: u32,
}

impl Drop for SilhouetteBlock {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_silhouette_beziers_free)(self.data, self.count) }
    }
}

/// `options` packed into a `CadaclysmBlacksmithSvgOptions` -- as [`crate::SvgOptions`]'s
/// own reader-side packing, but with no scene to default `up` from: a solid carries no
/// convention of its own, so `options.up` falls back to [`Up::Z`] rather than a scene's.
/// Colour text in `stroke`/`background` is read by the kernel's own parser.
fn build_svg_options(api: &Api, options: &SvgOptions) -> Result<sys::CadaclysmBlacksmithSvgOptions> {
    let stroke = options.stroke.packed_with("svg: stroke", parse_colour)?;
    let background = match &options.background {
        Some(colour) => colour.packed_with("svg: background", parse_colour)?,
        None => crate::SVG_TRANSPARENT,
    };
    let mut raw: sys::CadaclysmBlacksmithSvgOptions = unsafe { std::mem::zeroed() };
    unsafe { (api.cadaclysm_blacksmith_svg_options_init)(&mut raw) };
    let (base_azimuth, base_elevation) = options.view.angles();
    raw.up = match options.up.unwrap_or(Up::Z) {
        Up::Y => 1,
        Up::Z => 0,
    };
    raw.azimuth = options.azimuth.unwrap_or(base_azimuth);
    raw.elevation = options.elevation.unwrap_or(base_elevation);
    raw.fov = options.fov;
    raw.width = options.width;
    raw.height = options.height;
    raw.margin = options.margin;
    raw.tolerance = options.tolerance;
    raw.stroke_width = options.stroke_width;
    raw.stroke = stroke;
    raw.background = background;
    raw.flags = u32::from(options.edges)
        | (u32::from(options.curves) << 1)
        | (u32::from(options.isocurves) << 2)
        | (u32::from(options.polylines) << 3)
        | (u32::from(options.silhouettes) << 4);
    Ok(raw)
}

/// Several solids' wireframe as one SVG's text, each its own `<g>` -- see
/// [`crate::SvgOptions`].
pub fn write_svg_text(solids: &[&Solid], options: &SvgOptions) -> Result<String> {
    let api = api()?;
    let raw = build_svg_options(api, options)?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let text_ptr = unsafe { (api.cadaclysm_blacksmith_svg_text)(handles.as_ptr(), handles.len(), &raw) };
    if text_ptr.is_null() {
        return Err(fail(api, "svg_text"));
    }
    let out = unsafe { text(text_ptr as *const c_char) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(text_ptr) };
    Ok(out)
}

/// [`write_svg_text`] written to `path` by the library itself, which names the file in
/// its refusal when it cannot.
pub fn write_svg(path: impl AsRef<FsPath>, solids: &[&Solid], options: &SvgOptions) -> Result<()> {
    let api = api()?;
    let raw = build_svg_options(api, options)?;
    let path = crate::c_path(path.as_ref())?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let ok = unsafe { (api.cadaclysm_blacksmith_svg)(handles.as_ptr(), handles.len(), path.as_ptr(), &raw) };
    if ok { Ok(()) } else { Err(fail(api, "svg")) }
}

/// Several solids and profiles' wireframes as one SVG's text, each its own `<g>` --
/// the pair the C API grew beside [`write_svg_text`]/[`write_svg`] so a drawing can
/// carry both kinds. Always calls the kernel's own drawing pair, never the
/// solids-only one -- a solids-only call through this function draws exactly what
/// [`write_svg_text`] does, refused in the same words, so there is one code path for
/// a mixed drawing and a solids-only one alike. Takes no view default of its own: an
/// `options.view` left at [`SvgOptions::default`]'s `Iso` stays `Iso`, the same as
/// [`Solid::svg_text`] -- only [`Profile::svg_text`]'s own no-`options` call defaults
/// to `Top`.
pub fn svg_text_of(solids: &[&Solid], profiles: &[&Profile], options: &SvgOptions) -> Result<String> {
    let api = api()?;
    let raw = build_svg_options(api, options)?;
    let solid_handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let profile_handles: Vec<_> = profiles.iter().map(|p| p.raw()).collect();
    let text_ptr = unsafe {
        (api.cadaclysm_blacksmith_drawing_svg_text)(
            solid_handles.as_ptr(),
            solid_handles.len(),
            profile_handles.as_ptr(),
            profile_handles.len(),
            &raw,
        )
    };
    if text_ptr.is_null() {
        return Err(fail(api, "drawing_svg_text"));
    }
    let out = unsafe { text(text_ptr as *const c_char) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(text_ptr) };
    Ok(out)
}

/// [`svg_text_of`] written to `path` by the library itself, which names the file in
/// its refusal when it cannot.
pub fn svg_of(path: impl AsRef<FsPath>, solids: &[&Solid], profiles: &[&Profile], options: &SvgOptions) -> Result<()> {
    let api = api()?;
    let raw = build_svg_options(api, options)?;
    let path = crate::c_path(path.as_ref())?;
    let solid_handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let profile_handles: Vec<_> = profiles.iter().map(|p| p.raw()).collect();
    let ok = unsafe {
        (api.cadaclysm_blacksmith_drawing_svg)(
            solid_handles.as_ptr(),
            solid_handles.len(),
            profile_handles.as_ptr(),
            profile_handles.len(),
            path.as_ptr(),
            &raw,
        )
    };
    if ok { Ok(()) } else { Err(fail(api, "drawing_svg")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- the SubD cage (The Kiln, Plan 2b) ------------------------------------------

    fn kernel_present() -> bool {
        if api().is_err() {
            eprintln!("skipped: no kernel library to build a SubD cage with");
            return false;
        }
        true
    }

    fn refused<T: fmt::Debug>(result: Result<T>) -> String {
        result.expect_err("the kernel should have refused this").message().to_string()
    }

    fn cube() -> Subd {
        Subd::cuboid([2.0, 2.0, 2.0], [1, 1, 1]).unwrap()
    }

    #[test]
    fn subd_structs_have_the_headers_sizes() {
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithSubdParts>(), 112);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithSubdMesh>(), 48);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithSubdReport>(), 80);
    }

    #[test]
    fn a_cuboid_cage_reads_back_as_copies_and_from_parts_is_its_inverse() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let mut positions = cage.positions().unwrap();
        assert_eq!(positions.len(), 8);
        let faces = cage.faces().unwrap();
        assert_eq!(faces.len(), 6);
        assert!(faces.iter().all(|f| f.len() == 4));
        assert!(cage.creases().unwrap().is_empty() && cage.pins().unwrap().is_empty());
        assert_eq!(cage.symmetry().unwrap(), None);
        assert_eq!(cage.selection().unwrap(), None);
        let before = positions.clone();
        positions[0] = [99.0; 3];
        assert_eq!(cage.positions().unwrap(), before, "writing to a read-back must not reach the cage");
        let again = Subd::from_parts(&before, &faces, &[], &[], None).unwrap();
        assert_eq!(again.positions().unwrap(), before);
        assert_eq!(again.faces().unwrap(), faces);
    }

    #[test]
    fn extrude_makes_a_new_cage_and_selects_the_faces() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let out = cage.extrude(&[1], 1.0).unwrap();
        assert_eq!(out.positions().unwrap().len(), 12);
        assert_eq!(out.selection().unwrap(), Some(SubdSelection::Faces(vec![1])));
        assert_eq!(cage.positions().unwrap().len(), 8);
    }

    #[test]
    fn creases_and_pins_are_set_read_and_cleared() {
        if !kernel_present() {
            return;
        }
        let creased = cube().crease(&[(0, 1)], true).unwrap();
        assert_eq!(creased.selection().unwrap(), Some(SubdSelection::Edges(vec![(0, 1)])));
        let both = creased.pin(&[6], true).unwrap();
        assert_eq!(both.creases().unwrap(), [(0, 1)]);
        assert_eq!(both.pins().unwrap(), [6]);
        assert_eq!(both.selection().unwrap(), Some(SubdSelection::Vertices(vec![6])));
        let rebuilt = Subd::from_parts(&both.positions().unwrap(), &both.faces().unwrap(), &[(0, 1)], &[6], None).unwrap();
        assert_eq!((rebuilt.creases().unwrap(), rebuilt.pins().unwrap()), (vec![(0, 1)], vec![6]));
        let cleared = both.crease(&[(0, 1)], false).unwrap().pin(&[6], false).unwrap();
        assert!(cleared.creases().unwrap().is_empty() && cleared.pins().unwrap().is_empty());
    }

    #[test]
    fn a_mirrored_half_keeps_its_symmetry_until_it_is_baked_or_made_whole() {
        if !kernel_present() {
            return;
        }
        let whole = Subd::cuboid([2.0, 2.0, 2.0], [2, 1, 1]).unwrap();
        let half = whole.mirror_on(SubdAxis::X).unwrap();
        let (axis, tolerance) = half.symmetry().unwrap().expect("a mirrored half has a symmetry");
        assert_eq!(axis, SubdAxis::X);
        assert!(tolerance > 0.0);
        assert_eq!(half.selection().unwrap(), None);
        assert!(half.positions().unwrap().len() < whole.positions().unwrap().len());
        let kept = Subd::from_parts(&half.positions().unwrap(), &half.faces().unwrap(), &[], &[], Some((axis, tolerance))).unwrap();
        assert_eq!(kept.positions().unwrap(), half.positions().unwrap());
        assert_eq!(kept.symmetry().unwrap(), Some((axis, tolerance)));
        assert_eq!(half.full().unwrap().positions().unwrap().len(), whole.positions().unwrap().len());
        assert_eq!(half.mirror_off().unwrap().symmetry().unwrap(), None);
    }

    #[test]
    fn an_edge_loop_runs_round_the_ring_and_is_empty_off_an_edge() {
        if !kernel_present() {
            return;
        }
        let grid = Subd::cuboid([2.0, 2.0, 2.0], [2, 2, 2]).unwrap();
        let face = grid.faces().unwrap().remove(0);
        let (a, b) = (face[0], face[1]);
        let ring = grid.edge_loop((a, b)).unwrap();
        assert!(ring.len() >= 4, "{ring:?}");
        assert_eq!(ring[0], (a.min(b), a.max(b)));
        let cage = cube();
        let face = cage.faces().unwrap().remove(0);
        assert!(cage.edge_loop((face[0], face[2])).unwrap().is_empty(), "a diagonal is not an edge");
        assert!(cage.edge_loop((0, 99)).unwrap().is_empty());
    }

    #[test]
    fn transform_moves_the_selection_by_a_column_major_matrix() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let before = cage.positions().unwrap();
        let turn = [0.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        let all: Vec<u32> = (0..8).collect();
        let turned = cage.transform(&SubdSelection::Vertices(all), &turn).unwrap().positions().unwrap();
        for (p, q) in before.iter().zip(&turned) {
            assert!((q[0] + p[1]).abs() < 1e-12 && (q[1] - p[0]).abs() < 1e-12 && (q[2] - p[2]).abs() < 1e-12, "{p:?} -> {q:?}");
        }
        let one = cage.transform(&SubdSelection::Vertices(vec![0]), &turn).unwrap().positions().unwrap();
        assert_ne!(one[0], before[0]);
        assert_eq!(&one[1..], &before[1..], "only vertex 0 moves");
        let slide = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 3.0, 0.0, 0.0, 1.0];
        let moved = cage.transform(&SubdSelection::Edges(vec![(0, 1)]), &slide).unwrap();
        assert_eq!(moved.positions().unwrap()[0][0], before[0][0] + 3.0);
        assert_eq!(moved.selection().unwrap(), Some(SubdSelection::Edges(vec![(0, 1)])));
        let message = refused(cage.transform(&SubdSelection::Vertices(vec![0]), &[1.0, 2.0, 3.0]));
        assert!(message.contains("matrix"), "{message}");
    }

    #[test]
    fn inset_and_insert_loop_cut_the_cage_and_refuse_a_bad_position() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        assert_eq!(cage.inset(&[1], 0.25, false).unwrap().faces().unwrap().len(), 10);
        let looped = cage.insert_loop((0, 1), 0.5).unwrap();
        assert_eq!(looped.positions().unwrap().len(), 12);
        assert!(matches!(looped.selection().unwrap(), Some(SubdSelection::Edges(_))));
        let message = refused(cage.insert_loop((0, 1), 1.5));
        assert!(message.starts_with("bad selection: "), "{message}");
    }

    #[test]
    fn a_smooth_mesh_is_a_whole_copy_that_outlives_its_cage() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let mesh = cage.smooth_mesh(2).unwrap();
        let n = mesh.positions.len();
        assert!(n > 8 && mesh.normals.len() == n);
        for v in &mesh.normals {
            assert!(((v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt() - 1.0).abs() < 1e-9, "{v:?}");
        }
        assert!(mesh.indices.iter().flatten().all(|&i| (i as usize) < n));
        assert_eq!(mesh.triangle_face.len(), mesh.indices.len());
        assert!(mesh.triangle_face.iter().all(|&f| f < 6));
        assert!(cage.smooth_mesh(1).unwrap().positions.len() < n);
        assert_eq!(cage.smooth_mesh(2).unwrap().positions, mesh.positions);
        let message = refused(cage.smooth_mesh(7));
        assert!(message.contains("levels"), "{message}");
        let copy = mesh.clone();
        // Dropping the cage frees the memory a view would have pointed into; the copy is whole.
        drop(cage);
        assert_eq!(mesh, copy);
        assert_eq!(mesh.positions.len(), n);
        let kept: f64 = mesh.positions.iter().flatten().map(|c| c.abs()).sum();
        assert!(kept.is_finite() && kept > 0.0);
    }

    #[test]
    fn pick_answers_an_element_nothing_near_or_a_refusal() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let corner = cage.positions().unwrap()[6];
        let mesh = cage.smooth_mesh(3).unwrap();
        let dist = |p: &[f64; 3]| (0..3).map(|k| (p[k] - corner[k]).powi(2)).sum::<f64>();
        let near = *mesh.positions.iter().min_by(|a, b| dist(a).total_cmp(&dist(b))).unwrap();
        assert_eq!(cage.pick(near, SubdElements::Vertices).unwrap(), Some(SubdSelection::Vertices(vec![6])));
        match cage.pick(near, SubdElements::Edges).unwrap() {
            Some(SubdSelection::Edges(e)) => assert!(e.len() == 1 && (e[0].0 == 6 || e[0].1 == 6), "{e:?}"),
            other => panic!("{other:?}"),
        }
        assert!(matches!(cage.pick(near, SubdElements::Faces).unwrap(), Some(SubdSelection::Faces(f)) if f.len() == 1));
        // The refusal first, so a stale error would show on the far point's answer.
        let message = refused(cage.pick([f64::NAN, 0.0, 0.0], SubdElements::Vertices));
        assert_eq!(message, "bad selection: pick: point is not finite");
        assert_eq!(cage.pick([100.0, 100.0, 100.0], SubdElements::Vertices).unwrap(), None);
    }

    #[test]
    fn a_cuboid_cage_becomes_a_closed_solid_within_its_report() {
        if !kernel_present() {
            return;
        }
        let (solid, report) = cube().to_solid(SubdSolidOptions::default()).unwrap();
        assert_eq!((report.regular, report.refined), (0, 24));
        assert!(report.levels >= 2 && report.steps >= 1, "{report:?}");
        assert!(report.deviation <= 1e-4 && report.g1_angle_deg <= 0.1, "{report:?}");
        assert!(report.deviation_at.iter().chain(&report.g1_at).all(|c| c.is_finite()));
        assert!(solid.manifold().unwrap().is_closed);
        assert!(solid.mass(0.0).unwrap().volume > 0.0);
        let explicit = SubdSolidOptions { tolerance: 1e-4, g1_angle: 0.1, max_levels: 6 };
        assert!(cube().to_solid(explicit).is_ok());
        assert_eq!(SubdSolidOptions::default(), explicit);
    }

    #[test]
    fn an_uncreased_cylinder_is_refused_and_the_default_cylinder_converts() {
        if !kernel_present() {
            return;
        }
        let message = refused(Subd::cylinder(1.0, 2.0, 8, 1, false).unwrap().to_solid(SubdSolidOptions::default()));
        assert!(message.contains("subd:") && message.contains("tangent break"), "{message}");
        // `creased_rims` true is what the other wrappers default to: it must convert.
        let (_, report) = Subd::cylinder(1.0, 2.0, 8, 1, true).unwrap().to_solid(SubdSolidOptions::default()).unwrap();
        assert!(report.deviation <= 1e-4 && report.g1_angle_deg <= 0.1, "{report:?}");
    }

    #[test]
    fn the_primitives_have_faces_and_their_refusals_are_the_kernels() {
        if !kernel_present() {
            return;
        }
        assert!(!Subd::cylinder(1.0, 2.0, 8, 2, true).unwrap().faces().unwrap().is_empty());
        assert!(!Subd::sphere(1.0, 2).unwrap().faces().unwrap().is_empty());
        assert!(!Subd::torus(3.0, 1.0, 12, 8).unwrap().faces().unwrap().is_empty());
        assert_eq!(refused(Subd::cuboid([2.0; 3], [0, 1, 1])), "bad selection: cuboid: segments >= 1");
        assert!(refused(Subd::sphere(1.0, 2000)).contains("1024"));
    }

    #[test]
    fn from_parts_refusals_are_the_kernels() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        let (positions, faces) = (cage.positions().unwrap(), cage.faces().unwrap());
        let message = refused(Subd::from_parts(&positions, &faces, &[(0, 6)], &[], None));
        assert!(message.starts_with("bad selection: "), "{message}");
        let none: &[[f64; 3]] = &[];
        let message = refused(Subd::from_parts(none, &faces, &[], &[], None));
        assert!(message.contains("vertex_count"), "{message}");
    }

    #[test]
    fn the_pipeline_extrude_inset_to_solid_is_closed_and_writes_step() {
        if !kernel_present() {
            return;
        }
        let cage = cube().extrude(&[1], 0.5).unwrap().inset(&[1], 0.25, false).unwrap();
        let (solid, report) = cage.to_solid(SubdSolidOptions::default()).unwrap();
        assert!(solid.manifold().unwrap().is_closed);
        assert!(report.deviation <= 1e-4, "{report:?}");
        let text = solid.step_text(None, Unit::Millimetre).unwrap();
        assert!(text.starts_with("ISO-10303-21;") && text.contains("ADVANCED_FACE"));
    }

    #[test]
    fn a_child_cage_outlives_its_parent_and_the_edge_loop_handle_is_freed() {
        if !kernel_present() {
            return;
        }
        let cage = cube();
        for _ in 0..200 {
            let _ = cage.edge_loop((0, 1)).unwrap();
            let _ = cage.edge_loop((0, 99)).unwrap();
        }
        let child = cage.extrude(&[0], 1.0).unwrap();
        drop(cage);
        assert_eq!(child.positions().unwrap().len(), 12, "a child outlives the cage it was made from");
    }

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

    /// Needs the real kernel library (`CADACLYSM_BLACKSMITH_LIBRARY`), like the other
    /// kernel tests in this module that build a solid; skips quietly without one. The
    /// skip check is `version()`, not `rgb` itself: a `rgb` that always errs (broken
    /// colour parsing, say) must not be able to hide behind a "no library" skip.
    #[test]
    fn rgb_reads_css_names_through_the_library() {
        if let Err(err) = version() {
            eprintln!("skipped: {err} (no kernel library to read colour names with)");
            return;
        }
        assert_eq!(rgb("red").unwrap(), [1.0, 0.0, 0.0]);
        assert_eq!(rgb("#0f0").unwrap(), [0.0, 1.0, 0.0]);
        assert_eq!(rgb(" RebeccaPurple ").unwrap(), [0x66 as f64 / 255.0, 0x33 as f64 / 255.0, 0x99 as f64 / 255.0]);
        assert!(rgb("notacolour").unwrap_err().to_string().contains("a CSS colour name"));
        let solid = Solid::cuboid(1.0, 1.0, 1.0).unwrap(); // the file's real box constructor
        assert_eq!(solid.coloured("navy", None).unwrap().colour().unwrap(), Some([0.0, 0.0, 128.0 / 255.0]));
        assert_eq!(solid.coloured([0.5, 0.5, 0.5], None).unwrap().colour().unwrap(), Some([0.5, 0.5, 0.5]));
    }

    #[test]
    fn packed_refuses_bogus_text_without_the_paint_clause() {
        if api().is_err() {
            eprintln!("skipped: no kernel library to read colour names with");
            return;
        }
        assert_eq!(packed("navy").unwrap(), 0x00_00_80);
        let err = packed("bogus").unwrap_err().to_string();
        assert!(err.contains("not 'bogus'"), "{err}");
        assert!(!err.contains("0..1"), "{err}");
    }

    /// Needs the real kernel library, like `rgb_reads_css_names_through_the_library`.
    #[test]
    fn svg_stroke_takes_a_css_name() {
        if version().is_err() {
            eprintln!("skipped: no kernel library to read colour names with");
            return;
        }
        let solid = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        let options = SvgOptions { stroke: packed("red").unwrap().into(), ..Default::default() };
        let text = solid.svg_text(&options).unwrap();
        assert!(text.to_lowercase().contains("#ff0000"), "{text}");
    }

    /// `stroke`/`background` take colour text, read by the kernel's own parser, and refuse
    /// text it does not know naming the field. Needs the real kernel library.
    #[test]
    fn svg_background_takes_colour_text() {
        if version().is_err() {
            eprintln!("skipped: no kernel library to read colour names with");
            return;
        }
        let solid = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        let options = SvgOptions { stroke: "Lime".into(), background: Some("Navy".into()), ..Default::default() };
        let text = solid.svg_text(&options).unwrap();
        assert!(text.contains("#000080"), "{text}");
        assert!(text.to_lowercase().contains("#00ff00"), "{text}");
        let bogus = SvgOptions { background: Some("bogus".into()), ..Default::default() };
        let err = solid.svg_text(&bogus).unwrap_err().to_string();
        assert!(err.starts_with("svg: background:"), "{err}");
    }

    #[test]
    fn a_line_edge_has_a_unit_direction() {
        let edge = Edge { index: 0, kind: "line".into(), faces: vec![], segments: vec![[[0.0; 3], [0.0, 0.0, 4.0]]], curve: None };
        assert_eq!(edge.direction(), Some([0.0, 0.0, 1.0]));
        let arc = Edge { kind: "circle".into(), ..edge };
        assert_eq!(arc.direction(), None);
    }

    #[test]
    fn a_hit_is_copied_out_field_for_field() {
        let spot = |k: u32| sys::CadaclysmBlacksmithSpot {
            loop_index: k,
            segment: k + 1,
            t: k as f64 + 0.25,
            face: NONE,
            u: k as f64 + 0.5,
            v: k as f64 + 0.75,
        };
        let raw = sys::CadaclysmBlacksmithHit {
            run: true,
            touch: false,
            start: sys::CadaclysmBlacksmithPoint { x: 1.0, y: 2.0, z: 3.0 },
            end: sys::CadaclysmBlacksmithPoint { x: 4.0, y: 5.0, z: 6.0 },
            a_start: spot(10),
            a_end: spot(20),
            b_start: spot(30),
            b_end: spot(40),
        };
        let hit = Hit::from(&raw);
        assert!(hit.run && !hit.touch);
        assert_eq!((hit.start, hit.end), ([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]));
        let loops: Vec<u32> = [hit.a_start, hit.a_end, hit.b_start, hit.b_end].iter().map(|s| s.loop_index).collect();
        assert_eq!(loops, [10, 20, 30, 40]);
        assert_eq!(hit.b_end, Spot { loop_index: 40, segment: 41, t: 40.25, face: NONE, u: 40.5, v: 40.75 });
        // The header's layout, which `#[repr(C)]` reproduces: 40-byte spots, 216-byte hits.
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithSpot>(), 40);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithHit>(), 216);
    }

    #[test]
    fn a_curve_is_copied_out_field_for_field() {
        let knots = [0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 3.0, 3.0, 3.0];
        let poles = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0];
        let weights = [1.0, 2.0, 1.0, 2.0, 1.0, 2.0];
        let kind = std::ffi::CString::new("nurbs").unwrap();
        let raw = sys::CadaclysmBlacksmithCurve {
            kind: kind.as_ptr(),
            origin: sys::CadaclysmBlacksmithPoint { x: 1.0, y: 2.0, z: 3.0 },
            x: sys::CadaclysmBlacksmithPoint { x: 4.0, y: 5.0, z: 6.0 },
            y: sys::CadaclysmBlacksmithPoint { x: 7.0, y: 8.0, z: 9.0 },
            z: sys::CadaclysmBlacksmithPoint { x: 10.0, y: 11.0, z: 12.0 },
            radius: 0.5,
            radius2: 0.25,
            t0: 0.5,
            t1: 2.5,
            degree: 3,
            knots: knots.as_ptr(),
            knot_count: knots.len() as u32,
            poles: poles.as_ptr(),
            pole_count: 6,
            weights: weights.as_ptr(),
        };
        let curve = unsafe { Curve::from_raw(&raw) };
        assert_eq!(curve.kind, "nurbs");
        assert_eq!((curve.origin, curve.x), ([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]));
        assert_eq!((curve.y, curve.z), ([7.0, 8.0, 9.0], [10.0, 11.0, 12.0]));
        assert_eq!((curve.radius, curve.radius2, curve.t0, curve.t1, curve.degree), (0.5, 0.25, 0.5, 2.5, 3));
        assert_eq!(curve.knots, knots);
        assert_eq!(curve.poles.len(), 6);
        assert_eq!((curve.poles[0], curve.poles[5]), ([1.0, 2.0, 3.0], [16.0, 17.0, 18.0]));
        assert_eq!(curve.weights.as_deref(), Some(&weights[..]));
        assert_eq!(curve.knots.len(), curve.poles.len() + curve.degree as usize + 1);
        // Null pointers read as empty, a null `weights` as `None`; the header's 184 bytes.
        let plain = sys::CadaclysmBlacksmithCurve { knots: std::ptr::null(), knot_count: 0, poles: std::ptr::null(), pole_count: 0, weights: std::ptr::null(), ..raw };
        let plain = unsafe { Curve::from_raw(&plain) };
        assert!(plain.knots.is_empty() && plain.poles.is_empty() && plain.weights.is_none());
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithCurve>(), 184);
    }

    #[test]
    fn a_chain_and_an_overlap_are_copied_out_ring_by_ring() {
        let points = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 5.0, 5.0, 5.0, 6.0, 5.0, 5.0, 6.0, 6.0, 5.0, 5.0, 6.0, 5.0];
        let raw = sys::CadaclysmBlacksmithChain { points: points.as_ptr(), point_count: 3, face_a: 2, face_b: 7, closed: true, tangent: false, has_curve: false };
        let chain = unsafe { Chain::from_raw(&raw, None) };
        assert_eq!(chain.points, [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0]]);
        assert_eq!((chain.closed, chain.faces, chain.tangent, chain.curve), (true, (2, 7), false, None));
        // Two rings: a triangle, then a quad that runs to `point_count` -- the last ring's end.
        let starts = [0u32, 3];
        let raw = sys::CadaclysmBlacksmithOverlap { face_a: 1, face_b: 4, points: points.as_ptr(), loop_offsets: starts.as_ptr(), point_count: 7, loop_count: 2 };
        let overlap = unsafe { Overlap::from_raw(&raw) };
        assert_eq!(overlap.faces, (1, 4));
        assert_eq!(overlap.loops.len(), 2);
        assert_eq!(overlap.loops[0], [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0]]);
        assert_eq!(overlap.loops[1], [[5.0, 5.0, 5.0], [6.0, 5.0, 5.0], [6.0, 6.0, 5.0], [5.0, 6.0, 5.0]]);
        // Zero rings is legal (a partial overlap whose outlines cross); the header's sizes.
        let none = sys::CadaclysmBlacksmithOverlap { loop_offsets: std::ptr::null(), loop_count: 0, ..raw };
        assert!(unsafe { Overlap::from_raw(&none) }.loops.is_empty());
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithChain>(), 24);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithOverlap>(), 32);
    }

    /// The kernel twin of the reader's `a_fem_edge_and_vertex_are_read_field_for_field`:
    /// the same eleven and three fields, over the kernel's own structs. Needs no library.
    ///
    /// Catches what that one catches, and one thing it cannot: the two ABIs' FEM structs
    /// are identical in layout, so a kernel `from_raw` that read the *reader's* fields
    /// would compile and pass -- until the two headers diverge. Pinning both sides
    /// separately is what keeps that honest.
    #[test]
    fn a_kernel_fem_edge_and_vertex_are_read_field_for_field() {
        let nodes = [3u32, 4, 5, 6];
        let runs = [0u32, 2];
        let raw = sys::CadaclysmBlacksmithFemEdge {
            id: 1,
            nodes: nodes.as_ptr(),
            node_count: nodes.len() as u32,
            runs: runs.as_ptr(),
            run_count: runs.len() as u32,
            face_a: 0,
            face_b: NONE,
            end_a: 0,
            end_b: 2,
            closed: false,
            seam: true,
        };
        let edge = unsafe { FemEdge::from_raw(&raw) };
        assert_eq!((edge.id, edge.faces, edge.ends), (1, (0, NONE), (0, 2)));
        assert_eq!(edge.nodes, nodes);
        assert_eq!(edge.runs, runs);
        assert!(!edge.closed && edge.seam);
        assert_eq!(edge.chains().collect::<Vec<_>>(), [&nodes[..2], &nodes[2..]]);

        let at = FemVertex::from_raw(&sys::CadaclysmBlacksmithFemVertex { node: 0, point: [-1.0, 2.0, -3.0], has_position: true });
        assert_eq!((at.node, at.point, at.has_position), (0, [-1.0, 2.0, -3.0], true));
        let none = FemVertex::from_raw(&sys::CadaclysmBlacksmithFemVertex { node: NONE, point: [0.0; 3], has_position: false });
        assert!(none.node == NONE && !none.has_position);

        // The kernel header's own sizes, which are the reader header's -- the two FEM
        // struct families were published with the same layout on purpose.
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithFemOptions>(), 24);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithFemMeshView>(), 104);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithFemEdge>(), 56);
        assert_eq!(std::mem::size_of::<sys::CadaclysmBlacksmithFemVertex>(), 40);
    }

    /// The kernel twin of the reader's `mesh64_and_bounds64_keep_coordinates_far_from_the_origin`:
    /// a cuboid moved far out keeps its coordinates in `mesh64`/`bounds_at64`, where
    /// `mesh`/`bounds_at`'s `f32`-widened ones do not. Catches the same bug as that test,
    /// on the kernel's own tessellation cache rather than the reader's document mesh.
    ///
    /// Needs the real kernel library (`CADACLYSM_BLACKSMITH_LIBRARY`); skips quietly
    /// without one, as the reader's far-from-origin test does.
    #[test]
    fn kernel_mesh64_and_bounds64_keep_coordinates_far_from_the_origin() {
        // `Solid::cuboid` is centred on the origin it is built at, so the low-y corner
        // after this translate is the translate's y minus the half-extent (0.5), not
        // the translate's y itself.
        let low_y = -2_600_000.987_654_321 - 0.5;
        let far = Solid::cuboid(1.0, 1.0, 1.0).and_then(|s| s.translate(1_000_000.123_456_789, -2_600_000.987_654_321, 450.5));
        let mut far = match far {
            Ok(far) => far,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library to build the far-from-origin cuboid with)");
                return;
            }
        };

        let mesh64 = far.mesh64(0.05).expect("mesh64 for a freshly built solid");
        assert!(
            mesh64.positions.iter().any(|p| (p[1] - low_y).abs() < 1e-6),
            "kernel mesh64 lost the far low-y corner: {:?}",
            mesh64.positions
        );
        assert!(
            mesh64.positions.iter().any(|p| ((p[1] as f32) as f64 - p[1]).abs() > 1e-3),
            "kernel mesh64 carries no coordinate f32 cannot hold, so this test cannot tell mesh64 from mesh widened"
        );

        let (lo64, _) = far.bounds_at64(0.05).expect("bounds_at64");
        let (lo32, _) = far.bounds_at(0.05).expect("bounds_at");
        assert!((lo64[1] - low_y).abs() < 1e-6, "kernel bounds64 lost the far corner: {lo64:?}");
        assert!(
            (lo64[1] - lo32[1]).abs() > 1e-3,
            "kernel bounds64 agrees with bounds's f32-mesh-derived box to the bit, so it is not exact where f32 is not: {} vs {}",
            lo64[1],
            lo32[1]
        );
    }

    /// A solid built with no name has none; a fresh library-built one skips quietly
    /// without a kernel library, as [`kernel_mesh64_and_bounds64_keep_coordinates_far_from_the_origin`]
    /// does. Needs no library at all: `Solid::cuboid` fails cleanly and this test returns
    /// early either way, but it is written the same shape as the others so it keeps
    /// working once a library is present.
    #[test]
    fn an_unnamed_solid_has_no_name() {
        let cube = match Solid::cuboid(1.0, 1.0, 1.0) {
            Ok(cube) => cube,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        assert_eq!(cube.name(), None);
        let named = cube.named("part").expect("named");
        assert_eq!(named.name().as_deref(), Some("part"));
        assert!(cube.named("").is_err(), "an empty name was accepted");
    }

    /// The spec §5 assembly facts, over a small build of `_shared_assembly()`'s shape:
    /// placement names ordered and numbered past a taken one (fact 1), a cycle refused
    /// naming it (fact 5), an explicit name taken twice refused (fact 6), a mirrored raw
    /// frame refused in the library's own words rather than `Frame::new`'s (fact 7), an
    /// assembly that places nothing refused at `step_text` (fact 8), and naming through
    /// `place` (part of fact 10). Skips quietly without a kernel library, as the other
    /// library-backed test in this module does.
    #[test]
    fn assembly_facts_hold_as_python_checks_them() {
        let bolt = match Solid::cylinder(1.0, 6.0).and_then(|s| s.named("bolt")) {
            Ok(bolt) => bolt,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let plate = Solid::cuboid(20.0, 10.0, 2.0).and_then(|s| s.named("plate")).expect("plate");

        let bracket = Assembly::new("bracket").expect("bracket");
        bracket.place_solid(&plate, &Frame::xy([0.0; 3]), None).expect("place plate");
        let first = bracket.place_solid(&bolt, &Frame::xy([5.0, 5.0, 2.0]), None).expect("place bolt 1");
        let second = bracket.place_solid(&bolt, &Frame::xy([15.0, 5.0, 2.0]), None).expect("place bolt 2");
        assert_eq!((first.as_str(), second.as_str()), ("bolt", "bolt 2")); // fact 1

        let root = Assembly::new("frame").expect("frame");
        root.place_assembly(&bracket, &Frame::xy([0.0; 3]), Some("left")).expect("place left");

        // fact 5: a cycle is refused, naming it.
        let cycle = bracket.place_assembly(&root, &Frame::xy([0.0; 3]), None);
        assert!(cycle.unwrap_err().to_string().contains("bracket → frame → bracket"));

        // fact 6: an explicit name already taken is refused.
        assert!(root.place_assembly(&bracket, &Frame::xy([0.0; 3]), Some("left")).is_err());

        // fact 7: a mirrored raw frame is refused in the library's own words, not
        // `Frame::new`'s -- see `Frame::raw_unchecked`'s own doc.
        let mirrored = Frame::raw_unchecked([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, -1.0]);
        let refused = root.place_solid(&bolt, &mirrored, None).unwrap_err();
        assert!(refused.to_string().contains("right-handed and orthonormal"), "{refused}");

        // fact 8: an assembly placing nothing is refused at step_text().
        assert!(Assembly::new("x").expect("x").step_text(None, Unit::Millimetre).is_err());

        // part of fact 10: place keeps the solid's name as the placement's default.
        assert_eq!(bolt.name().as_deref(), Some("bolt"));
        let placed = bolt.place(&Frame::xy([1.0, 2.0, 3.0])).expect("place");
        assert_eq!(placed.name().as_deref(), Some("bolt"));
    }

    use crate::view::{fake, objects::{present, Shown}, ViewOptions};

    #[test]
    fn a_rectangle_profile_draws_as_one_closed_line_from_the_top() {
        let rect = match Profile::rect(2.0, 1.0) {
            Ok(rect) => rect,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let runs = rect.polylines(DEFAULT_TOLERANCE).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].len(), 5, "four corners and the first again");
        assert_eq!(runs[0].first(), runs[0].last());
        assert!(runs[0].iter().all(|p| p[2] == 0.0));
        let (segments, rgb) = rect.segments(&ViewOptions::default()).unwrap();
        assert_eq!((segments.len(), rgb), (4, None));
        // Lines are the whole picture: edges off does not touch the edges layer.
        fake::take();
        present(fake::leaked(), Shown::Lines(segments, rgb), &ViewOptions { edges: false, ..ViewOptions::default() }, "Profile", SvgView::Top, Up::Z, false).unwrap();
        let log = fake::take();
        assert!(log.iter().any(|l| l == "standard 0"), "the top view: {log:?}");
        assert!(!log.iter().any(|l| l.starts_with("layer 1")), "{log:?}");
    }

    #[test]
    fn a_solid_is_shown_by_its_handle() {
        let cube = match Solid::cuboid(1.0, 1.0, 1.0) {
            Ok(cube) => cube,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let view = crate::view::View::open(fake::leaked(), crate::view::target_own(), &ViewOptions::default(), "part", Up::Z).unwrap();
        fake::take();
        let item = view.show_solid(&cube, 0.05, Some([1.0, 0.0, 0.0])).unwrap();
        assert_eq!(item.id(), 15);
        assert_eq!(fake::take(), ["solid 0.05 rgb=[1.0, 0.0, 0.0]"]);
        assert!(!cube.as_ptr().is_null());
    }

    /// `Profile` is `Sync`, and the kernel caches a profile's polylines on it: threads
    /// asking one profile at different tolerances must each get their own answer whole.
    #[test]
    fn one_profile_gives_polylines_to_many_threads_at_once() {
        let (rect, circle) = match (Profile::rect(2.0, 1.0), Profile::circle(1.0)) {
            (Ok(rect), Ok(circle)) => (rect, circle),
            (Err(err), _) | (_, Err(err)) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let tolerances = [0.1, 0.01];
        let expected: Vec<[Vec<Vec<[f32; 3]>>; 2]> = [&rect, &circle]
            .iter()
            .map(|p| tolerances.map(|t| p.polylines(t).unwrap()))
            .collect();
        assert_ne!(expected[1][0][0].len(), expected[1][1][0].len(), "the circle's two tolerances differ");
        let start = std::sync::Barrier::new(8);
        std::thread::scope(|s| {
            for thread in 0..8 {
                let (profiles, expected, start) = ([&rect, &circle], &expected, &start);
                s.spawn(move || {
                    start.wait();
                    for i in 0..2000 {
                        let which = (thread + i) % 2;
                        let runs = profiles[i % 2].polylines(tolerances[which]).expect("polylines");
                        assert!(!runs.is_empty());
                        for run in &runs {
                            assert!(!run.is_empty() && run.first() == run.last(), "{run:?}");
                            assert!(run.iter().all(|p| p[2] == 0.0), "{run:?}");
                        }
                        assert_eq!(runs, expected[i % 2][which]);
                    }
                });
            }
        });
    }

    /// `None`, `&options` and `Some(&options)` are one argument: a solid's `None` is the
    /// defaults, a profile's `None` its own Top view rather than `SvgOptions::default()`.
    #[test]
    fn an_options_argument_takes_none_a_reference_or_some() {
        let (cube, rect) = match (Solid::cuboid(1.0, 2.0, 3.0), Profile::rect(2.0, 1.0)) {
            (Ok(cube), Ok(rect)) => (cube, rect),
            (Err(err), _) | (_, Err(err)) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let defaults = SvgOptions::default();
        let solid = cube.svg_text(None).unwrap();
        assert_eq!(solid, cube.svg_text(&defaults).unwrap());
        assert_eq!(solid, cube.svg_text(Some(&defaults)).unwrap());
        let top = rect.svg_text(None).unwrap();
        assert_ne!(top, rect.svg_text(&defaults).unwrap(), "a profile's None is Top, not the Iso default");
        let named_top = SvgOptions { view: SvgView::Top, ..SvgOptions::default() };
        assert_eq!(top, rect.svg_text(&named_top).unwrap());
    }

    #[test]
    fn face_triangles_count_every_triangle_face_by_face() {
        let mut cube = match Solid::cuboid(1.0, 1.0, 1.0) {
            Ok(cube) => cube,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let triangles = cube.mesh(DEFAULT_TOLERANCE).unwrap().indices.len() / 3;
        let counts = cube.face_triangles(DEFAULT_TOLERANCE).unwrap().to_vec();
        assert_eq!(counts.len(), 6);
        assert_eq!(counts.iter().sum::<u32>() as usize, triangles);
    }

    #[test]
    fn a_solid_is_shown_by_handle_with_the_edges_layer_as_asked() {
        let cube = match Solid::cuboid(1.0, 1.0, 1.0) {
            Ok(cube) => cube,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        fake::take();
        present(fake::leaked(), Shown::Solid(&cube), &ViewOptions { edges: false, ..ViewOptions::default() }, "Solid", SvgView::Iso, Up::Z, false).unwrap();
        assert_eq!(
            fake::take(),
            [
                "create Solid y_up=0 w=0 h=0 surfaces=0 window=- offscreen=0",
                "solid 0.05 rgb=-",
                "layer 1 false",
                "standard 1",
                "orbit -69.813 48.869",
                "frame 0",
                "run",
                "destroy",
            ]
        );
    }

    fn count_of(text: &str, needle: &str) -> usize {
        text.matches(needle).count()
    }

    /// `text` with every `FILE_NAME(` line dropped -- STEP's own timestamp line, which
    /// changes call to call even when nothing else does.
    fn no_stamp(text: &str) -> String {
        text.lines().filter(|line| !line.starts_with("FILE_NAME(")).collect::<Vec<_>>().join("\n")
    }

    /// Spec 2026-09-25 section 6's fixture, as `mechanism_facts_hold_as_the_shared_spec_checks_them`
    /// built it inline and `paired` (below) builds on too: a bolt and plate, a bracket
    /// joining two bolts to the plate by a `"screw"` joint, and an arm placing the plate,
    /// the bracket and a pin bolt, joined by a `"shoulder"` joint. `None` without a kernel
    /// library, as every library-backed test in this module reports.
    fn mechanism() -> Option<(Solid, Solid, Assembly, Assembly)> {
        let bolt = match Solid::cylinder(1.0, 6.0).and_then(|s| s.named("bolt")) {
            Ok(bolt) => bolt,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return None;
            }
        };
        let plate = Solid::cuboid(20.0, 10.0, 2.0).and_then(|s| s.named("plate")).expect("plate");

        let bracket = Assembly::new("bracket").expect("bracket");
        bracket.place_solid(&plate, &Frame::xy([0.0; 3]), None).expect("place plate");
        bracket.place_solid(&bolt, &Frame::xy([5.0, 5.0, 2.0]), None).expect("place bolt 1");
        bracket.place_solid(&bolt, &Frame::xy([15.0, 5.0, 2.0]), None).expect("place bolt 2");
        bracket.link("fixed", &["plate"]).expect("link fixed");
        bracket.link("bolts", &["bolt", "bolt 2"]).expect("link bolts");
        bracket.joint("screw", "fixed", "bolts").expect("joint screw");

        let arm = Assembly::new("arm").expect("arm");
        arm.place_solid(&plate, &Frame::xy([0.0; 3]), Some("base")).expect("place base");
        arm.place_assembly(&bracket, &Frame::xy([0.0, 0.0, 10.0]), Some("upper")).expect("place upper");
        arm.place_solid(&bolt, &Frame::xy([5.0, 5.0, 2.0]), Some("pin")).expect("place pin");
        arm.link("ground", &["base"]).expect("link ground");
        arm.link("upper arm", &["upper", "pin"]).expect("link upper arm");
        arm.joint("shoulder", "ground", "upper arm").expect("joint shoulder");
        Some((bolt, plate, bracket, arm))
    }

    /// `Assembly::link`/`Assembly::joint`, at parity with the Python reference's
    /// `_mechanism()` and its two mechanism tests in `test_cadaclysm_blacksmith.py` --
    /// see Node's `test/blacksmith.test.js` for the same facts worked out. Skips quietly
    /// without a kernel library, as the other library-backed test in this module does.
    #[test]
    fn mechanism_facts_hold_as_the_shared_spec_checks_them() {
        let Some((_bolt, _plate, _bracket, arm)) = mechanism() else { return };

        // Fact 1: the default schema (no explicit schema) carries the kinematic entities.
        let step = arm.step_text(None, Unit::Millimetre).expect("step_text");
        assert!(step.contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"));
        assert_eq!(count_of(&step, "=KINEMATIC_LINK("), 4);
        assert_eq!(count_of(&step, "=RIGID_LINK_REPRESENTATION("), 6);
        assert_eq!(count_of(&step, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION("), 6);
        assert_eq!(count_of(&step, "=KINEMATIC_JOINT("), 2);
        assert_eq!(count_of(&step, "=KINEMATIC_TOPOLOGY_STRUCTURE("), 2);

        // Fact 2: an explicit schema without kinematic entities is refused.
        let refused = arm.step_text(Some("config_control_design"), Unit::Millimetre).unwrap_err();
        assert!(refused.to_string().contains("no kinematic entities"), "{refused}");

        // Fact 3: each of the eleven refusals raises with exactly its message, and
        // afterwards the STEP text (with `FILE_NAME(` lines stripped) is unchanged.
        let before = no_stamp(&arm.step_text(None, Unit::Millimetre).expect("step_text"));
        let refusals: Vec<(Box<dyn Fn() -> Result<()> + '_>, &str)> = vec![
            (Box::new(|| arm.link("", &["base"])), "link: a name cannot be empty"),
            (Box::new(|| arm.link("ground", &["base"])), "link: assembly 'arm' already has a link named 'ground'"),
            (Box::new(|| arm.link("free", &[])), "link: link 'free' names no placements"),
            (Box::new(|| arm.link("free", &["base", "base"])), "link: link 'free' names placement 'base' twice"),
            (Box::new(|| arm.link("free", &["bolt"])), "link: assembly 'arm' has no placement named 'bolt'"),
            (
                Box::new(|| arm.link("free", &["pin"])),
                "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'",
            ),
            (Box::new(|| arm.joint("", "ground", "upper arm")), "joint: a name cannot be empty"),
            (
                Box::new(|| arm.joint("shoulder", "upper arm", "ground")),
                "joint: assembly 'arm' already has a joint named 'shoulder'",
            ),
            (Box::new(|| arm.joint("wrist", "ground", "hand")), "joint: assembly 'arm' has no link named 'hand'"),
            (Box::new(|| arm.joint("wrist", "ground", "ground")), "joint: joint 'wrist' joins link 'ground' to itself"),
            (
                Box::new(|| arm.joint("wrist", "ground", "upper arm")),
                "joint: assembly 'arm' already joins 'ground' to 'upper arm'",
            ),
        ];
        for (call, message) in &refusals {
            let err = call().unwrap_err();
            assert_eq!(err.to_string(), *message);
        }
        assert_eq!(no_stamp(&arm.step_text(None, Unit::Millimetre).expect("step_text")), before);

        // Fact 5: read-back through `to_scene`. Checked ahead of fact 4's reverse "back"
        // joint, so the joint list below is exactly the two joints the fixture built.
        let scene = arm.to_scene(None).expect("to_scene");
        let link_names: Vec<String> = scene.links().iter().map(|l| l.name()).collect();
        assert_eq!(link_names, ["fixed", "bolts", "ground", "upper arm"]);
        let node_counts: Vec<usize> = scene.links().iter().map(|l| l.nodes().len()).collect();
        assert_eq!(node_counts, [1, 2, 1, 2]);
        let joint_facts: Vec<(String, u32, u32)> =
            scene.joints().iter().map(|j| (j.name(), j.start().index(), j.end().index())).collect();
        assert_eq!(joint_facts, [("screw".to_string(), 0, 1), ("shoulder".to_string(), 2, 3)]);
        assert!(!scene.diagnostics().iter().any(|d| d.starts_with("kinematics:")));

        // Fact 4: the reverse pair is a new joint.
        arm.joint("back", "upper arm", "ground").expect("joint back");
    }

    /// Within `1e-9` -- the tolerance every pair-facts assertion below checks frames,
    /// freedom ranges and posed coordinates at.
    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// A frame's origin, as rows ([`crate::blacksmith::Pair::frame_start`]'s shape) give it.
    fn frame_origin(frame: &[[f64; 4]; 4]) -> [f64; 3] {
        [frame[0][3], frame[1][3], frame[2][3]]
    }

    /// A frame's z axis, as rows give it.
    fn frame_z(frame: &[[f64; 4]; 4]) -> [f64; 3] {
        [frame[0][2], frame[1][2], frame[2][2]]
    }

    /// Spec 2026-09-28's fixture: [`mechanism`]'s bracket and arm, each given a pair, plus
    /// a state and a declared base on `arm` -- Python's `_paired()`.
    fn paired() -> Option<(Solid, Solid, Assembly, Assembly)> {
        let (bolt, plate, bracket, arm) = mechanism()?;
        bracket
            .pair(
                "screw",
                "prismatic",
                &Frame::xy([1.0, 2.0, 3.0]),
                &PairOptions { end_frame: Some(Frame::xy([4.0, 2.0, 3.0])), ..Default::default() },
            )
            .expect("pair screw");
        arm.pair(
            "shoulder",
            "revolute",
            &Frame::xy([0.0, 0.0, 10.0]),
            &PairOptions { ranges: Some(vec![(Some(-1.5), Some(1.5))]), ..Default::default() },
        )
        .expect("pair shoulder");
        arm.state("reach", &[("shoulder", &[0.5])]).expect("state reach");
        arm.base("ground").expect("base ground");
        Some((bolt, plate, bracket, arm))
    }

    /// Python's `_posed_frame()`: two copies of a bracket whose bolt turns on `turn`
    /// (revolute about z through (10, 5, 2)), placed as `left` and `right/rear`.
    fn posed_frame() -> Option<Assembly> {
        let bolt = Solid::cuboid(1.0, 1.0, 6.0).and_then(|s| s.named("bolt")).ok()?;
        let plate = Solid::cuboid(20.0, 10.0, 2.0).and_then(|s| s.named("plate")).ok()?;
        let bracket = Assembly::new("bracket").expect("bracket");
        bracket.place_solid(&plate, &Frame::xy([0.0; 3]), None).expect("plate");
        bracket.place_solid(&bolt, &Frame::xy([5.0, 5.0, 2.0]), None).expect("bolt");
        bracket.link("fixed", &["plate"]).expect("fixed");
        bracket.link("bolts", &["bolt"]).expect("bolts");
        bracket.joint("turn", "fixed", "bolts").expect("turn");
        bracket.pair("turn", "revolute", &Frame::xy([10.0, 5.0, 2.0]), &PairOptions::default()).expect("pair turn");
        let frame = Assembly::new("frame").expect("frame");
        frame.place_assembly(&bracket, &Frame::xy([0.0; 3]), Some("left")).expect("left");
        frame.place_assembly(&bracket, &Frame::xy([100.0, 0.0, 0.0]), Some("right/rear")).expect("right/rear");
        Some(frame)
    }

    fn step_of(a: &Assembly) -> String {
        no_stamp(&a.step_text(None, Unit::Millimetre).expect("step_text"))
    }

    /// Facts 1 and 2 (by step text): the posed copy differs from the rest, the original is unchanged.
    #[test]
    fn posed_moves_the_shoulder() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        let before = step_of(&arm);
        let posed = arm.posed(&[("shoulder", &[0.5])], None, None).expect("posed");
        assert_eq!(posed.name(), "arm");
        assert_ne!(step_of(&posed), before);
        assert_eq!(step_of(&arm), before);
        // no rows at all is allowed and poses nothing
        assert_eq!(step_of(&arm.posed(&[], None, None).expect("posed nothing")), before);
    }

    /// Facts 3 and 4: the bare `turn` names both copies; a path escapes the `/` inside `right/rear`.
    #[test]
    fn posed_refuses_an_ambiguous_name_and_takes_a_path_with_a_slash() {
        let Some(frame) = posed_frame() else { return };
        let before = step_of(&frame);
        let refused = frame.posed(&[("turn", &[0.3])], None, None).unwrap_err().to_string();
        assert_eq!(refused, "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path");
        let posed = frame.posed(&[("right\\/rear/turn", &[0.3])], None, None).expect("posed by path");
        assert_eq!(posed.name(), "frame");
        assert_ne!(step_of(&posed), before);
        assert_eq!(step_of(&frame.posed(&[("right\\/rear/turn", &[0.0])], None, None).expect("posed zero")), before);
        assert_eq!(step_of(&frame), before);
    }

    /// A state, a ground link, and the kernel's own refusals.
    #[test]
    fn posed_takes_a_state_and_a_ground_and_refuses_with_the_kernels_words() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        let before = step_of(&arm);
        let by_state = arm.posed(&[], Some("reach"), None).expect("by state");
        let by_row = arm.posed(&[("shoulder", &[0.5])], None, None).expect("by row");
        assert_eq!(step_of(&by_state), step_of(&by_row));
        let held = arm.posed(&[("shoulder", &[0.5])], None, Some("upper arm")).expect("held");
        assert_ne!(step_of(&held), step_of(&by_row));
        assert_eq!(
            arm.posed(&[("shoulder", &[2.0])], None, None).unwrap_err().to_string(),
            "posed: value 0 of joint 'shoulder' is 2, outside its range"
        );
        assert_eq!(
            arm.posed(&[], Some("fold"), None).unwrap_err().to_string(),
            "posed: assembly 'arm' has no state named 'fold'"
        );
        assert_eq!(step_of(&arm), before);
    }

    /// Fact 1: `arm.step_text()` carries exactly the pair/state entity counts the Python
    /// reference's `_paired()` fixture gives (`test_a_paired_mechanism_is_written_as_ap242_kinematic_pairs_and_states`).
    #[test]
    fn a_paired_mechanism_is_written_as_ap242_kinematic_pairs_and_states() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        let text = arm.step_text(None, Unit::Millimetre).expect("step_text");
        assert_eq!(count_of(&text, "=MECHANISM_REPRESENTATION("), 2);
        assert_eq!(count_of(&text, "=PAIR_REPRESENTATION_RELATIONSHIP("), 2);
        assert_eq!(count_of(&text, "REVOLUTE_PAIR_WITH_RANGE"), 1);
        assert_eq!(count_of(&text, "PRISMATIC_PAIR"), 1);
        assert_eq!(count_of(&text, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION("), 1);
        assert_eq!(count_of(&text, "=MECHANISM_STATE_REPRESENTATION("), 1);
    }

    /// Facts 2, 3, 4, 5, 6 and 9: read back through `to_scene`, at parity with
    /// `test_a_paired_mechanism_reads_back_through_to_scene`. Skips quietly without the
    /// reader library too, as `mechanism_facts_hold_as_the_shared_spec_checks_them`'s own
    /// read-back fact does.
    #[test]
    fn a_paired_mechanism_reads_back_through_to_scene() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        let scene = match arm.to_scene(None) {
            Ok(scene) => scene,
            Err(err) => {
                eprintln!("skipped: {err} (no reader library)");
                return;
            }
        };

        // Fact 2: shoulder's pair is revolute, both world frames at (0, 0, 10) with z
        // (0, 0, 1), one freedom Rz ranged [-1.5, 1.5].
        let shoulder = scene.joints().into_iter().find(|j| j.name() == "shoulder").expect("shoulder joint");
        let s_pair = shoulder.pair().expect("shoulder pair");
        assert_eq!(s_pair.kind(), PairKind::Revolute);
        for frame in [s_pair.frame_start(), s_pair.frame_end()] {
            assert!(frame_origin(&frame).iter().zip([0.0, 0.0, 10.0]).all(|(a, b)| close(*a, b)), "{frame:?}");
            assert!(frame_z(&frame).iter().zip([0.0, 0.0, 1.0]).all(|(a, b)| close(*a, b)), "{frame:?}");
        }
        let freedoms = s_pair.freedoms();
        assert_eq!(freedoms.len(), 1);
        assert_eq!(freedoms[0].motion, Motion::Rotation);
        assert_eq!(freedoms[0].axis, FreedomAxis::Z);
        assert!(close(freedoms[0].lower.expect("lower"), -1.5));
        assert!(close(freedoms[0].upper.expect("upper"), 1.5));

        // Fact 3: screw's pair is prismatic with no ranges; world start (1, 2, 13), end (4, 2, 13).
        let screw = scene.joints().into_iter().find(|j| j.name() == "screw").expect("screw joint");
        let sc_pair = screw.pair().expect("screw pair");
        assert_eq!(sc_pair.kind(), PairKind::Prismatic);
        assert!(sc_pair.freedoms().iter().all(|f| f.lower.is_none() && f.upper.is_none()));
        assert!(frame_origin(&sc_pair.frame_start()).iter().zip([1.0, 2.0, 13.0]).all(|(a, b)| close(*a, b)));
        assert!(frame_origin(&sc_pair.frame_end()).iter().zip([4.0, 2.0, 13.0]).all(|(a, b)| close(*a, b)));

        // Fact 4: the base is 'ground'; one state 'reach' with one row (shoulder, [0.5]).
        let base = scene.base().expect("base");
        assert_eq!(base.name(), "ground");
        let states = scene.states();
        assert_eq!(states.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["reach"]);
        let reach = &states[0];
        assert_eq!(reach.values.len(), 1);
        assert_eq!(reach.values[0].joint.name(), "shoulder");
        assert!(close(reach.values[0].values[0], 0.5));

        // Fact 5: pose_state(reach) carries the pin node's origin (5, 5, 2) to
        // (5cos0.5 - 5sin0.5, 5sin0.5 + 5cos0.5, 2) within 1e-9.
        let pose = scene.pose_state(reach, None).expect("pose_state");
        let upper_arm = scene.links().into_iter().find(|l| l.name() == "upper arm").expect("upper arm link");
        let pin_node = upper_arm
            .nodes()
            .into_iter()
            .find(|n| {
                let t = n.transform();
                close(t[0][3], 5.0) && close(t[1][3], 5.0) && close(t[2][3], 2.0)
            })
            .expect("pin node at (5, 5, 2)");
        let want = [5.0 * 0.5f64.cos() - 5.0 * 0.5f64.sin(), 5.0 * 0.5f64.sin() + 5.0 * 0.5f64.cos(), 2.0];
        let posed = pose.transform(pin_node);
        assert!(close(posed[0][3], want[0]) && close(posed[1][3], want[1]) && close(posed[2][3], want[2]), "{posed:?}");

        // Fact 6: pose([(screw, [3.0])]) leaves every node at rest (drawn at 3); pose at
        // 5.0 moves each 'bolts' node by (2, 0, 0).
        let pose3 = scene.pose(&[StateValue { joint: screw, values: vec![3.0] }], None).expect("pose 3");
        let pose5 = scene.pose(&[StateValue { joint: screw, values: vec![5.0] }], None).expect("pose 5");
        let bolts = scene.links().into_iter().find(|l| l.name() == "bolts").expect("bolts link");
        for node in bolts.nodes() {
            let rest = node.transform();
            let t3 = pose3.transform(node);
            let t5 = pose5.transform(node);
            for i in 0..3 {
                assert!(close(t3[i][3], rest[i][3]), "pose at rest value moved a node");
            }
            assert!(close(t5[0][3], rest[0][3] + 2.0) && close(t5[1][3], rest[1][3]) && close(t5[2][3], rest[2][3]));
        }

        // Fact 9: no diagnostic names kinematics.
        assert!(!scene.diagnostics().iter().any(|d| d.starts_with("kinematics:")));
    }

    /// Motion sequences: `sequence` writes one, the reader reads it back; an unknown state
    /// is refused with the kernel's exact text.
    #[test]
    fn a_written_sequence_reads_back_and_a_bad_state_is_refused() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        arm.state("rest", &[("shoulder", &[0.0])]).expect("state rest");
        arm.sequence("swing", &[("rest", 0.0, "linear"), ("reach", 1.0, "linear")], true).expect("sequence swing");
        assert_eq!(
            arm.sequence("bad", &[("rest", 0.0, "linear"), ("nowhere", 1.0, "linear")], false).unwrap_err().to_string(),
            "sequence: assembly 'arm' has no state named 'nowhere'"
        );
        let scene = match arm.to_scene(None) {
            Ok(scene) => scene,
            Err(err) => {
                eprintln!("skipped: {err} (no reader library)");
                return;
            }
        };
        let sequences = scene.sequences();
        assert_eq!(sequences.len(), 1);
        let swing = &sequences[0];
        assert_eq!(swing.name, "swing");
        assert!(swing.closed);
        assert_eq!(swing.seconds_per_unit, Some(1.0));
        let rows: Vec<(String, f64, &str)> =
            swing.segments.iter().map(|s| (s.state.name.clone(), s.t, s.interpolation.name())).collect();
        assert_eq!(rows, [("rest".to_string(), 0.0, "linear"), ("reach".to_string(), 1.0, "linear")]);
    }

    /// Fact 7: every bad `pair`/`state`/`base` call refuses with exactly its message and
    /// changes nothing -- the unpaired `"back"` trick: `step_text()`'s refusal text is
    /// identical before and after the batch.
    #[test]
    fn every_bad_pair_state_or_base_call_is_refused_and_changes_nothing() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        arm.joint("back", "upper arm", "ground").expect("joint back");

        let unpaired_message = || arm.step_text(None, Unit::Millimetre).unwrap_err().to_string();
        let before = unpaired_message();

        let xy0 = Frame::xy([0.0; 3]);
        let turned = Frame::at([0.0, 0.0, 0.0], [0.0, 0.0, 1.0], Some([0.0, 1.0, 0.0])).expect("frame at");
        let refusals: Vec<(Box<dyn Fn() -> Result<()> + '_>, &str)> = vec![
            (Box::new(|| arm.pair("shoulder", "revolute", &Frame::xy([0.0, 0.0, 10.0]), &PairOptions::default())),
             "pair: joint 'shoulder' already has a pair"),
            (Box::new(|| arm.pair("back", "orbital", &xy0, &PairOptions::default())),
             "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, \
              spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"),
            (Box::new(|| arm.pair("back", "screw", &xy0, &PairOptions::default())), "pair: a screw needs a non-zero pitch"),
            (
                Box::new(|| {
                    arm.pair(
                        "back",
                        "revolute",
                        &xy0,
                        &PairOptions { ranges: Some(vec![(Some(-1.0), Some(1.0)), (Some(-1.0), Some(1.0))]), ..Default::default() },
                    )
                }),
                "pair: 'revolute' has 1 freedoms, but 2 ranges were given",
            ),
            (
                Box::new(|| arm.pair("back", "revolute", &xy0, &PairOptions { ranges: Some(vec![]), ..Default::default() })),
                "pair: 'revolute' has 1 freedoms, but 0 ranges were given",
            ),
            (
                Box::new(|| {
                    arm.pair("back", "revolute", &xy0, &PairOptions { ranges: Some(vec![(Some(1.0), Some(-1.0))]), ..Default::default() })
                }),
                "pair: range 0 of joint 'back' has lower >= upper",
            ),
            (
                Box::new(|| arm.pair("back", "prismatic", &turned, &PairOptions { end_frame: Some(xy0), ..Default::default() })),
                "pair: joint 'back' is prismatic, but its end frame is turned 90\u{b0} about -z, \
                 which prismatic (does not turn) cannot make",
            ),
            (Box::new(|| arm.state("overreach", &[("shoulder", &[5.0])])), "state: value 0 of joint 'shoulder' is outside its range"),
            (Box::new(|| arm.base("upper arm")), "base: assembly 'arm' already has base 'ground'"),
        ];
        for (call, message) in &refusals {
            let err = call().unwrap_err();
            assert_eq!(err.to_string(), *message);
        }
        assert_eq!(unpaired_message(), before);
    }

    /// Fact 8: a joint with no pair is refused only when `step_text()` is written, with
    /// exactly this message.
    #[test]
    fn a_joint_without_a_pair_is_refused_at_write_time() {
        let Some((_bolt, _plate, _bracket, arm)) = paired() else { return };
        arm.joint("back", "upper arm", "ground").expect("joint back");
        let err = arm.step_text(None, Unit::Millimetre).unwrap_err();
        assert_eq!(
            err.to_string(),
            "assembly_step: assembly 'arm': joint 'back' has no pair; a mechanism with pairs needs one on every joint (AP242)"
        );
    }

    /// Fact 9's `pair_freedom_count` half.
    #[test]
    fn pair_freedom_count_reports_known_and_unknown_kinds() {
        if let Err(err) = Solid::cylinder(1.0, 6.0) {
            eprintln!("skipped: {err} (no kernel library)");
            return;
        }
        assert_eq!(pair_freedom_count("spherical"), 3);
        assert_eq!(pair_freedom_count("revolute"), 1);
        assert_eq!(pair_freedom_count("fully_constrained"), 0);
        assert_eq!(pair_freedom_count("not_a_kind"), 0);
    }

    /// Controller ruling, fact 10: a one-sided range survives the round trip. An
    /// implementation that always sent `has_lower`/`has_upper` as true would pass every
    /// other fact but fail this one.
    #[test]
    fn a_one_sided_pair_range_survives_the_round_trip() {
        let plate = match Solid::cuboid(20.0, 10.0, 2.0) {
            Ok(plate) => plate,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        let bolt = Solid::cylinder(1.0, 6.0).expect("bolt");
        let hinge = Assembly::new("hinge").expect("hinge");
        hinge.place_solid(&plate, &Frame::xy([0.0; 3]), Some("base")).expect("place base");
        hinge.place_solid(&bolt, &Frame::xy([0.0, 0.0, 2.0]), Some("arm")).expect("place arm");
        hinge.link("base", &["base"]).expect("link base");
        hinge.link("arm", &["arm"]).expect("link arm");
        hinge.joint("j", "base", "arm").expect("joint j");
        hinge
            .pair("j", "revolute", &Frame::xy([0.0; 3]), &PairOptions { ranges: Some(vec![(None, Some(1.0))]), ..Default::default() })
            .expect("pair j");

        let scene = match hinge.to_scene(None) {
            Ok(scene) => scene,
            Err(err) => {
                eprintln!("skipped: {err} (no reader library)");
                return;
            }
        };
        let j = scene.joints().into_iter().find(|j| j.name() == "j").expect("joint j");
        let freedoms = j.pair().expect("pair").freedoms();
        assert_eq!(freedoms.len(), 1);
        assert_eq!(freedoms[0].lower, None);
        assert!(close(freedoms[0].upper.expect("upper"), 1.0));
    }

    // ---- machining ----------------------------------------------------------------------

    /// `p` extruded by 1 and read back through `Solid::bounds`: `[xmin, xmax, ymin, ymax]`,
    /// as Go's and Node's own smoke fixtures measure a profile's footprint.
    fn footprint(p: &Profile) -> [f64; 4] {
        let solid = Solid::extrude(p, &Frame::xy([0.0; 3]), 1.0).expect("extrude for footprint");
        let (min, max) = solid.bounds().expect("bounds for footprint");
        [min[0], max[0], min[1], max[1]]
    }

    fn assert_footprint(p: &Profile, expected: [f64; 4], tolerance: f64) {
        let got = footprint(p);
        for i in 0..4 {
            assert!((got[i] - expected[i]).abs() <= tolerance, "footprint {got:?} != {expected:?}");
        }
    }

    /// A 40x30x10 block on z=0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill
    /// misses.
    fn pocketed_block() -> Solid {
        let block = Solid::cuboid(40.0, 30.0, 10.0).unwrap().translate(0.0, 0.0, 5.0).unwrap();
        let pocket = Solid::cuboid(20.0, 10.0, 8.0).unwrap().translate(0.0, 0.0, 6.0).unwrap();
        block.cut(&pocket, DEFAULT_TOLERANCE).unwrap()
    }

    #[test]
    fn profile_offset_grows_and_shrinks_a_rectangle() {
        let rect = Profile::rect(20.0, 10.0).unwrap();
        let grown = rect.offset(2.0, 0.01).unwrap();
        assert_eq!(grown.len(), 1);
        assert_footprint(&grown[0], [-12.0, 12.0, -7.0, 7.0], 1e-3);
        let shrunk = rect.offset(-2.0, 0.01).unwrap();
        assert_eq!(shrunk.len(), 1);
        assert_footprint(&shrunk[0], [-8.0, 8.0, -3.0, 3.0], 1e-3);
        let eaten = rect.offset(-6.0, 0.01).unwrap();
        assert!(eaten.is_empty());
        let err = rect.offset(f64::NAN, 0.01).unwrap_err();
        assert_eq!(err.to_string(), "profile_offset: distance must be finite");
    }

    #[test]
    fn profile_to_arcs_fits_a_spline_within_tolerance() {
        let spline = Profile::spline(&[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]], 3, None, true).unwrap();
        let fitted = spline.to_arcs(0.01).unwrap();
        assert_footprint(&fitted, footprint(&spline), 0.011);
        let err = spline.to_arcs(0.0).unwrap_err();
        assert_eq!(err.to_string(), "profile_to_arcs: tolerance must be positive and finite");
    }

    #[test]
    fn solid_section_cuts_a_cuboid() {
        let cuboid = Solid::cuboid(20.0, 10.0, 5.0).unwrap();
        let middle = cuboid.section(0.0, 0.05).unwrap();
        assert_eq!(middle.len(), 1);
        assert_footprint(&middle[0], [-10.0, 10.0, -5.0, 5.0], 1e-3);
        let miss = cuboid.section(50.0, 0.05).unwrap();
        assert!(miss.is_empty());
        let err = cuboid.section(2.5, 0.05).unwrap_err();
        assert_eq!(err.to_string(), "solid_section: a face lies in the plane -- section a little above or below it");
    }

    #[test]
    fn a_pocketed_block_reports_four_corners_a_six_mm_end_mill_misses() {
        let block = pocketed_block();
        let end_mill = Tool::flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let stock = Stock::around(&block, 2.0).unwrap();
        let mut job = Job::new(&stock, 30.0, JOB_DEFAULT_CLEARANCE, JOB_DEFAULT_TOLERANCE, JOB_DEFAULT_NAME, JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION)
            .unwrap();
        let report = job.machine(&block, &end_mill, &[], None, None, 0.3, None).unwrap();
        assert_eq!(report.items().len(), 4);
        assert_eq!(report.text().lines().count(), 4);
        assert_eq!(report.to_string(), report.text());
        for item in report.items() {
            assert_eq!(item.kind, "corner");
            assert!(item.size > 0.0);
            assert!(!item.region.is_empty());
            assert!(!item.reason.is_empty());
        }
        let ops = job.operations().unwrap();
        assert!(!ops.is_empty());
        for op in &ops {
            assert!(!op.kind.is_empty());
            assert_eq!(op.tool, 1);
            assert!(!op.params.is_empty());
        }

        // A drill as the end mill is refused, and leaves the job as it was.
        let drill = Tool::drill(2, 5.0, 30.0, 150.0, 3000.0).unwrap();
        let fresh_stock = Stock::around(&block, 2.0).unwrap();
        let mut fresh = Job::new(&fresh_stock, 30.0, JOB_DEFAULT_CLEARANCE, JOB_DEFAULT_TOLERANCE, JOB_DEFAULT_NAME, JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION)
            .unwrap();
        let err = fresh.machine(&block, &drill, &[], None, None, 0.3, None).unwrap_err();
        assert!(err.to_string().contains("end mill must not be a drill"), "{err}");
        assert!(fresh.operations().unwrap().is_empty());
    }

    #[test]
    fn the_plate_is_machined_cleanly_by_one_end_mill_and_one_drill() {
        let plate_outline = Profile::rect(80.0, 50.0).unwrap().round(6.0, None, false).unwrap();
        let mut part = Solid::extrude(&plate_outline, &Frame::xy([0.0; 3]), 12.0).unwrap();
        let pocket_outline = Profile::rect(40.0, 24.0).unwrap().round(4.0, None, false).unwrap().with_hole(&Profile::circle(5.0).unwrap()).unwrap();
        let pocket_solid = Solid::extrude(&pocket_outline, &Frame::xy([0.0, 0.0, 7.0]), 5.0).unwrap();
        part = part.cut(&pocket_solid, DEFAULT_TOLERANCE).unwrap();
        for [x, y] in [[-32.0, -17.0], [-32.0, 17.0], [32.0, -17.0], [32.0, 17.0]] {
            let bore = Solid::cylinder(3.0, 12.0).unwrap().translate(x, y, 0.0).unwrap();
            part = part.cut(&bore, DEFAULT_TOLERANCE).unwrap();
        }

        let end_mill = Tool::flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let drill = Tool::drill(2, 6.0, 30.0, 150.0, 3000.0).unwrap();
        let stock = Stock::around(&part, 3.0).unwrap();
        let mut job = Job::new(&stock, 25.0, 1.0, 0.01, "plate", JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION).unwrap();
        let report = job.machine(&part, &end_mill, &[Some(&drill)], None, None, 0.3, None).unwrap();
        assert!(report.is_empty());
        assert_eq!(report.text(), "nothing left uncut");

        let ops = job.operations().unwrap();
        assert!(!ops.is_empty());
        assert_eq!(ops[0].kind, "face");
        assert!(ops.iter().any(|o| o.kind == "pocket"));
        let last = ops.last().unwrap();
        assert_eq!(last.kind, "drill");
        assert_eq!(last.params.get("points"), Some(&Some(4.0)));
        assert_eq!(last.params.get("peck"), Some(&None));

        let programs = job.gcode().unwrap();
        assert_eq!(programs.len(), 2);
        for p in &programs {
            assert!(p.tool >= 1);
            assert!(!p.name.is_empty());
            assert!(!p.text.is_empty());
        }

        let dir = std::env::temp_dir().join(format!("cadaclysm-smoke-cam-rust-{}", std::process::id()));
        let written = job.write_camotics(dir.join("plate.camotics")).unwrap();
        assert!(!written.is_empty());
        assert!(written.last().unwrap().ends_with("plate.camotics"));
        for w in &written {
            assert!(w.is_file(), "{} was not written", w.display());
        }
        std::fs::remove_dir_all(&dir).ok();

        // A NUL in a CAMotics stem is refused in the kernel's words, before the library is asked.
        let nul_stem = job.write_camotics(dir.join("a\0b.camotics")).unwrap_err();
        assert_eq!(nul_stem.to_string(), JOB_NUL_NAME);
        assert!(!dir.exists(), "a refused stem must not create the folder");
        // ... and a NUL in a name, whatever else is wrong with the job.
        let nul_name = Job::new(&stock, 25.0, 1.0, 0.01, "a\0b", JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION).unwrap_err();
        assert_eq!(nul_name.to_string(), JOB_NUL_NAME);
    }

    /// The spec's own example (2026-09-28-cam-automatic-design.md), driven with `face`,
    /// `contour`, `pocket` and `drill` called directly rather than through `machine` --
    /// the same inputs and expected values as Go's "four verbs by hand" fixture (commit
    /// `74b9553ec`), which exists for exactly this reason: `machine` is one separate C
    /// entry point that never calls these four wrapper methods, so nothing above proves
    /// their own FFI call shapes (argument order, `job_side`'s "outside"/"inside"/"on"
    /// mapping, the `xy` pointer/count in `drill`).
    #[test]
    fn the_four_verbs_by_hand_give_two_programs_with_the_specs_own_numbers() {
        let outline = Profile::rect(60.0, 40.0).unwrap().round(5.0, None, false).unwrap();
        let part = Solid::extrude(&outline, &Frame::xy([0.0; 3]), 20.0).unwrap();
        let end = Tool::flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let drill = Tool::drill(2, 5.0, 30.0, 150.0, 3000.0).unwrap();
        let stock = Stock::around(&part, 2.0).unwrap();
        let mut job = Job::new(&stock, 30.0, JOB_DEFAULT_CLEARANCE, JOB_DEFAULT_TOLERANCE, JOB_DEFAULT_NAME, JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION)
            .unwrap();

        job.face(&end, 20.0, 3.0, 1.0).unwrap();
        job.contour(&end, &outline, 20.0, 0.0, "outside", 2.0, true, false).unwrap();
        let levels = part.section(15.0, 0.05).unwrap();
        assert!(!levels.is_empty(), "job: section(15) is empty");
        job.pocket(&end, &levels[0], 20.0, 10.0, 2.4, 2.0).unwrap();
        job.drill(&drill, &[[10.0, 10.0], [40.0, 10.0]], 20.0, -1.0, Some(3.0)).unwrap();

        let programs = job.gcode().unwrap();
        assert_eq!(programs.len(), 2);
        assert_eq!(programs[0].tool, 1);
        assert_eq!(programs[0].name, "job-T1");
        assert!(programs[0].text.starts_with("(cadaclysm: job-T1, T1 flat D6)\n"), "{}", programs[0].text);
        assert_eq!(programs[1].tool, 2);
        assert_eq!(programs[1].name, "job-T2");
        assert!(programs[1].text.starts_with("(cadaclysm: job-T2, T2 drill D5)\n"), "{}", programs[1].text);

        let ops = job.operations().unwrap();
        let kinds: Vec<&str> = ops.iter().map(|o| o.kind.as_str()).collect();
        assert_eq!(kinds, ["face", "contour", "pocket", "drill"]);
        // `job_side`'s mapping: "outside" is the library's own 0.
        assert_eq!(ops[1].params.get("side"), Some(&Some(0.0)));
        let drill_op = &ops[3];
        assert_eq!(drill_op.params.get("peck"), Some(&Some(3.0)));
        assert_eq!(drill_op.params.get("points"), Some(&Some(2.0)));

        // A bad `side` is refused before the library is asked, and leaves the job unchanged.
        let before = job.operations().unwrap().len();
        let bad_side = job.contour(&end, &outline, 20.0, 0.0, "left", 2.0, true, false).unwrap_err();
        assert_eq!(bad_side.to_string(), "side must be 'outside', 'inside' or 'on'");
        assert_eq!(job.operations().unwrap().len(), before);

        // A `None` peck reads back as no peck at all through `Job::drill` directly, not
        // only through `Job::machine` (the plate fixture above covers that path).
        let mut no_peck_job = Job::new(&stock, 30.0, JOB_DEFAULT_CLEARANCE, JOB_DEFAULT_TOLERANCE, JOB_DEFAULT_NAME, JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION)
            .unwrap();
        no_peck_job.drill(&drill, &[[0.0, 0.0]], 20.0, -1.0, None).unwrap();
        let no_peck_ops = no_peck_job.operations().unwrap();
        assert_eq!(no_peck_ops[0].params.get("peck"), Some(&None));
    }

    // ---- Solid::silhouette_beziers ------------------------------------------------------
    // The curves where a body's surfaces turn away from the eye. The assertions are on values that
    // pin the layout, not only on lengths: a stride-16 unpack that reads a weight as a coordinate,
    // or points shifted by one slice, still gives arrays of the right length. Each skips quietly
    // without a kernel library, like this module's other library-needing tests.

    #[test]
    fn a_spheres_rim_has_its_end_points_on_it_to_1e_9_and_its_end_weights_exactly_one() {
        if api().is_err() {
            eprintln!("skipped: no kernel library to take a silhouette with");
            return;
        }
        let rim = Solid::sphere(2.0).unwrap().silhouette_beziers(None).unwrap();
        assert!(rim.count() > 0, "a sphere gave no rim");
        assert_eq!(rim.points.len(), rim.count() * 4, "four control points a curve");
        assert_eq!(rim.weights.len(), rim.count() * 4, "four weights a curve");
        let radius = |p: &[f64; 3]| (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt();
        for (c, (curve, w)) in rim.points.chunks_exact(4).zip(rim.weights.chunks_exact(4)).enumerate() {
            // Control points 0 and 3 are the arc's ends: on the sphere to 1e-9, with the
            // end weights exactly 1. The interior control points are not checked at all, and the
            // interior weights only to lie in (0, 1): both move with how the rim is subdivided.
            assert!((radius(&curve[0]) - 2.0).abs() <= 1e-9, "arc {c}: first control point at radius {}", radius(&curve[0]));
            assert!((radius(&curve[3]) - 2.0).abs() <= 1e-9, "arc {c}: last control point at radius {}", radius(&curve[3]));
            assert!(
                w[0] == 1.0 && w[3] == 1.0 && w[1] > 0.0 && w[1] < 1.0 && w[2] > 0.0 && w[2] < 1.0,
                "arc {c}: weights {w:?}, not 1, then two weights in (0, 1), then 1"
            );
        }
    }

    #[test]
    fn a_cylinders_rulings_are_polynomial_and_span_its_height() {
        if api().is_err() {
            eprintln!("skipped: no kernel library to take a silhouette with");
            return;
        }
        let (radius, height) = (1.0, 3.0);
        let front = SvgOptions { view: SvgView::Front, ..Default::default() };
        let rulings = Solid::cylinder(radius, height).unwrap().silhouette_beziers(&front).unwrap();
        assert!(rulings.count() > 0, "a cylinder gave no rulings");
        assert_eq!(rulings.points.len(), rulings.count() * 4);
        assert_eq!(rulings.weights.len(), rulings.count() * 4);
        assert!(rulings.weights.iter().all(|w| *w == 1.0), "a ruling carries a weight other than 1");
        for (k, p) in rulings.points.iter().enumerate() {
            assert!((p[0].hypot(p[1]) - radius).abs() <= 1e-6, "control point {k} {p:?} is off the cylinder's wall");
            // `hypot(x, y)` is symmetric in x and y, so it cannot tell them apart. The front view
            // looks along y and the silhouette of the cylinder sits on the x axis, at y = 0: that
            // is what pins x against y. Only |x| and |y| are asserted, not the sign of x and not
            // how many rulings there are.
            assert!((p[0].abs() - radius).abs() <= 1e-6, "control point {k} {p:?} is not at |x| = {radius}");
            assert!(p[1].abs() <= 1e-6, "control point {k} {p:?} is not at y = 0");
        }
        // The rulings run cap to cap, so their z extent is the height: that pins z against x and y.
        let (low, high) = rulings.points.iter().fold((f64::MAX, f64::MIN), |(lo, hi), p| (lo.min(p[2]), hi.max(p[2])));
        assert!((high - low - height).abs() <= 1e-6, "the rulings span z {low}..{high}, not a height of {height}");
    }

    #[test]
    fn an_infinite_tolerance_is_refused_and_an_all_planar_body_is_the_empty_answer_after_it() {
        if api().is_err() {
            eprintln!("skipped: no kernel library to take a silhouette with");
            return;
        }
        let sphere = Solid::sphere(2.0).unwrap();
        // Built BEFORE the refusal, not between it and the ask: every call that builds, reads or
        // writes geometry in the library runs under its `guard`, whose first act is `clear_error`
        // (blacksmith-capi lib.rs:117), so building the cuboid in between would wipe the refusal's
        // message. The order is build, refuse, ask. Nothing this wrapper does between the refusal
        // and the native call clears the slot, though: it packs the stroke as a number
        // (`SvgOptions::stroke` is a packed u32), so there is no
        // `cadaclysm_blacksmith_parse_colour` call (a `guard`, lib.rs:200) to wipe it as there is
        // in a wrapper that parses the text "#000000", and `build_svg_options` calls only
        // `cadaclysm_blacksmith_svg_options_init`, a bare struct fill (output.rs:699) that does not
        // clear. So the refusal's message is still in the slot when
        // `cadaclysm_blacksmith_silhouette_beziers` begins, and this test pins two things. First,
        // that the wrapper must not read the slot anywhere before the native call: a read before
        // packing and a read after packing both fail it. Second, that the library's own entry
        // clears the slot (the entry is a `guard`, output.rs:908): that one is read from the
        // source, not mutation-witnessed, since proving it would take a rebuilt library. The
        // reader's entry point has its own library-side pin,
        // `an_empty_answer_after_a_refusal_carries_no_stale_error`
        // (crates/cadaclysm-capi/tests/silhouette_abi.rs:401); there is no kernel-side equivalent.
        // Only calls under `guard` clear: `cadaclysm_blacksmith_solid_free` and
        // `cadaclysm_blacksmith_silhouette_beziers_free` just drop a box and the error getter does
        // not clear either, so a `Drop` running between the refusal and the ask cannot wipe the
        // slot.
        let cuboid = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let infinite = SvgOptions { tolerance: f64::INFINITY, ..Default::default() };
        let err = sphere.silhouette_beziers(&infinite).unwrap_err();
        assert!(err.message().contains("silhouette: "), "{err}");
        let none = cuboid.silhouette_beziers(None).expect("an empty silhouette is an answer");
        assert_eq!(none.count(), 0);
        assert!(none.points.is_empty() && none.weights.is_empty());
    }

    /// The block the kernel hands over is owned and is freed inside the call, so a second ask,
    /// for another eye, leaves the first answer as it was: front then iso gives two different
    /// silhouettes of one sphere, and the first is kept by the caller as a `Vec`.
    #[test]
    fn a_silhouette_outlives_the_next_one_asked() {
        if api().is_err() {
            eprintln!("skipped: no kernel library to take a silhouette with");
            return;
        }
        let sphere = Solid::sphere(2.0).unwrap();
        let front = SvgOptions { view: SvgView::Front, ..Default::default() };
        let iso = SvgOptions { view: SvgView::Iso, ..Default::default() };
        let first = sphere.silhouette_beziers(&front).unwrap();
        let (kept_points, kept_weights) = (first.points.clone(), first.weights.clone());
        let second = sphere.silhouette_beziers(&iso).unwrap();
        assert!(second.count() > 0);
        assert_ne!(second.points, kept_points, "the two views gave the same silhouette, so this cannot tell much");
        assert_eq!(first.points, kept_points);
        assert_eq!(first.weights, kept_weights);
        assert_eq!(sphere.silhouette_beziers(&front).unwrap(), first, "asking again for the same eye gives the same curves");
    }
}
