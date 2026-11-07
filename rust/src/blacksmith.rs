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
//! A second shared library, loaded on first use like the reader's: the copy the process
//! already holds, if one is loaded (a Python wheel's, say: see [`use_loaded`]); else from
//! `CADACLYSM_BLACKSMITH_LIBRARY`, else beside the executable, else a `lib/` or
//! `target/release` in an ancestor directory -- see [`sys::find_library`]. It keeps
//! its own license state, so [`license`] is its own call.
//!
//! # Documents
//!
//! A [`Document`] is a model as data, as the other wrappers' is: load the text a
//! `Document.save` wrote (in any language) and read each node's result back as an ordinary
//! [`Solid`] or [`Profile`], colours and all.
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
//!
//! # Tolerances
//!
//! A tolerance of 0 (or NaN) given to a verb that takes a distance tolerance -- a
//! boolean, fillet, shell, split, section, hit test, mesh, curve fit or profile verb --
//! opts into the model's own: [`effective_tolerance`], the larger of the loosest absolute
//! tolerance the inputs declare and the option `tolerance.relative` (default `1e-4`)
//! times their size. A solid declares what its file said ([`Solid::tolerances`], `None`
//! for what it did not say; [`crate::Scene::tolerances`] is the file's), every verb's
//! result inherits the loosest of its inputs', and [`Solid::with_tolerances`] sets it.
//! `tolerance.angular` (default one degree) stands in where nothing declares an angle.

use std::collections::BTreeMap;
use std::ffi::{c_char, CString};
use std::fmt;
use std::hash::{Hash, Hasher};
use std::ops::Mul;
use std::path::{Path as FsPath, PathBuf};
use std::ptr::{self, NonNull};
use std::rc::Rc;
use std::sync::Mutex;

use crate::{
    borrowed, groups, groups64, heal_from, health_from, text, Beziers64Data, Error, FreedomAxis, HealKinds, HealReport, HealthReport, Manifold, Mesh, Mesh64, Motion, Node, OpenOptions, PairKind, Result, Scene,
    StateValue, SvgOptions, SvgView, Tolerances, Up,
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

impl Error {
    /// The ids a [`Sketch`] refusal names: the constraints a new constraint, value or
    /// reference conflicts with, or the entities still using a point. Empty for any
    /// other error.
    pub fn ids(&self) -> &[u32] {
        &self.ids
    }
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

/// Bind the kernel library this process already holds -- the Python wheel's
/// `cadaclysm_blacksmith`, when the program embeds Python and a script has imported it --
/// and answer the file it was loaded from. An error where the process holds none, or where
/// this crate already bound another copy.
///
/// A solid handle is good only to the copy of the kernel that made it, and a viewer reads
/// solids through the copy already loaded, so an app with two copies hands the View solids
/// it cannot read. The first call that needs the kernel binds the held copy anyway, ahead of
/// every other place it looks ([`sys::find_library`]); this makes that choice explicit, and
/// fails rather than loading a second copy when nothing holds one yet.
pub fn use_loaded() -> Result<PathBuf> {
    sys::use_loaded().map_err(Error::new)?;
    library_path()
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
/// `"boolean.mesh_budget"`, `"boolean.finest_tolerance"`, `"profile_boolean.point_budget"`,
/// `"measure.default_accuracy"`, `"step.validation_properties"`,
/// `"step.validation_accuracy"`, `"tolerance.relative"` or
/// `"tolerance.angular"`. An error -- and nothing changed -- for a name that is
/// not an option or a value it does not take, saying which and what it takes. The last two
/// stamp a written STEP part file with each body's measured area, volume and centroid, there
/// for the kernel that reads the file to check the transfer against; off by default, since it
/// measures every body in the file at `"step.validation_accuracy"` (1e-5).
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

/// The tolerance a verb given a tolerance of 0 (or NaN) works at over `solids`: the larger of
/// the loosest absolute tolerance they declare ([`Solid::tolerances`]) and
/// `option("tolerance.relative")` times the largest of their sizes, never finer than their
/// coordinates can represent. 0 for no solids, or solids with nothing to size by -- which a
/// verb refuses.
pub fn effective_tolerance(solids: &[&Solid]) -> Result<f64> {
    let api = api()?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let t = unsafe { (api.cadaclysm_blacksmith_effective_tolerance)(handles.as_ptr(), handles.len()) };
    if t.is_nan() {
        return Err(fail(api, "effective_tolerance"));
    }
    Ok(t)
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

    /// The same plane facing the other way: x and y swapped, z reversed.
    pub fn flipped(&self) -> Frame {
        let z = self.z();
        let mut v = [0.0; 12];
        for (i, c) in self.origin().iter().chain(&self.y()).chain(&self.x()).chain(&[-z[0], -z[1], -z[2]]).enumerate() {
            v[i] = c + 0.0; // no -0.0 to print or compare
        }
        Frame { v }
    }

    /// This frame turned `radians` about `axis` through its origin, right-handed
    /// ([`Transform::rotation`]).
    pub fn rotated(&self, radians: f64, axis: [f64; 3]) -> Result<Frame> {
        let r = Transform::rotation(&[self.origin(), axis], radians)?.rows;
        let turn = |d: [f64; 3]| [0, 1, 2].map(|i| r[4 * i] * d[0] + r[4 * i + 1] * d[1] + r[4 * i + 2] * d[2]);
        Frame::new(self.origin(), turn(self.x()), turn(self.y()), turn(self.z()))
    }

    /// The point `p` in this frame's coordinates.
    pub fn to_local(&self, p: [f64; 3]) -> [f64; 3] {
        let o = self.origin();
        let d = [p[0] - o[0], p[1] - o[1], p[2] - o[2]];
        [dot(d, self.x()), dot(d, self.y()), dot(d, self.z())]
    }

    /// How far `p` lies above the frame's plane, along its z: negative below.
    pub fn distance_to(&self, p: [f64; 3]) -> f64 {
        let o = self.origin();
        dot([p[0] - o[0], p[1] - o[1], p[2] - o[2]], self.z())
    }

    /// The point `p` dropped onto the frame's plane along its z.
    pub fn closest_point(&self, p: [f64; 3]) -> [f64; 3] {
        let (d, z) = (self.distance_to(p), self.z());
        [p[0] - d * z[0], p[1] - d * z[1], p[2] - d * z[2]]
    }

    /// The least-squares plane through `points` (three or more, not on one line) as a frame,
    /// and the largest distance any point sits off it.
    pub fn fit(points: &[[f64; 3]]) -> Result<(Frame, f64)> {
        let api = api()?;
        let xyz: Vec<f64> = points.iter().flatten().copied().collect();
        let (mut out, mut deviation) = ([0.0; 12], 0.0);
        if !unsafe { (api.cadaclysm_blacksmith_frame_fit)(xyz.as_ptr(), points.len(), out.as_mut_ptr(), &mut deviation) } {
            return Err(fail(api, "frame_fit"));
        }
        Ok((Frame::of(out)?, deviation))
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

// ---- transforms -------------------------------------------------------------------

/// How far from rigid, or from a similarity, a map may be and still be told one: what
/// Python's `is_rigid`, `is_similarity` and the two decompositions default to.
pub const MAP_TOLERANCE: f64 = 1e-9;

const IDENTITY_ROWS: [f64; 16] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];

/// `N` doubles a library call writes to its `out` argument; its last error where it returns false.
fn written<const N: usize>(what: &str, call: impl FnOnce(&'static Api, *mut f64) -> bool) -> Result<[f64; N]> {
    let api = api()?;
    let mut out = [0.0; N];
    if !call(api, out.as_mut_ptr()) {
        return Err(fail(api, what));
    }
    Ok(out)
}

/// An affine map of space: a 4×4 matrix, row-major, its bottom row `0 0 0 1`. A value with
/// nothing to free; `a * b` (or [`Transform::compose`]) is `a` after `b`.
///
/// The constructors and the decompositions are the library's own, so every wrapper computes
/// them alike; [`Transform::point`] is local arithmetic. Equality is by the 16 numbers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform {
    rows: [f64; 16],
}

/// [`Transform::decompose_rigid`]: the map is `p -> orthogonal · p + translation`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RigidParts {
    pub translation: [f64; 3],
    /// The linear part: a rotation, or a rotation and a mirror.
    pub orthogonal: Transform,
}

/// [`Transform::decompose_similarity`]: the map is `p -> k · orthogonal · p + translation`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SimilarityParts {
    pub translation: [f64; 3],
    /// The linear part over `k`: a rotation, or a rotation and a mirror.
    pub orthogonal: Transform,
    /// The scale, positive.
    pub k: f64,
}

/// [`Transform::decompose_affine`], the polar split: the linear part is
/// `rotation · axes · diag(stretch) · axesᵀ`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AffineParts {
    pub translation: [f64; 3],
    /// Orthogonal, and the one carrying the mirror if the map has one.
    pub rotation: Transform,
    /// A proper rotation whose columns are the stretch directions.
    pub axes: Transform,
    /// The stretches, largest first.
    pub stretch: [f64; 3],
}

impl Default for Transform {
    fn default() -> Transform {
        Transform::identity()
    }
}

impl Transform {
    /// The map 16 numbers state, row-major. Refused for another count, a number not finite,
    /// or a bottom row not `0 0 0 1`.
    pub fn from_rows(rows: &[f64]) -> Result<Transform> {
        if rows.len() != 16 {
            return Err(Error::new(format!("Transform: a matrix is 16 numbers, got {}", rows.len())));
        }
        if !rows.iter().all(|v| v.is_finite()) {
            return Err(Error::new("Transform: not finite"));
        }
        let mut r = [0.0; 16];
        for (out, v) in r.iter_mut().zip(rows) {
            *out = v + 0.0; // no -0.0 to print or compare
        }
        if r[12..] != [0.0, 0.0, 0.0, 1.0] {
            return Err(Error::new("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)"));
        }
        Ok(Transform { rows: r })
    }

    /// The map four rows of four state, checked as [`Transform::from_rows`] checks.
    pub fn from_matrix(rows: [[f64; 4]; 4]) -> Result<Transform> {
        let flat: Vec<f64> = rows.iter().flatten().copied().collect();
        Transform::from_rows(&flat)
    }

    /// The map that moves nothing.
    pub fn identity() -> Transform {
        Transform { rows: IDENTITY_ROWS }
    }

    fn made(what: &str, call: impl FnOnce(&'static Api, *mut f64) -> bool) -> Result<Transform> {
        Transform::from_rows(&written::<16>(what, call)?)
    }

    /// `p + v`.
    pub fn translation(v: [f64; 3]) -> Result<Transform> {
        Transform::made("transform_translation", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_translation)(v.as_ptr(), out) })
    }

    /// A turn of `radians` about `axis` (a point and a direction), right-handed.
    pub fn rotation(axis: &AxisLine, radians: f64) -> Result<Transform> {
        let axis = axis_raw(axis);
        Transform::made("transform_rotation", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_rotation)(axis.as_ptr(), radians, out) })
    }

    /// The reflection across `plane`, its z the normal.
    pub fn mirror(plane: &Frame) -> Result<Transform> {
        Transform::made("transform_mirror", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_mirror)(plane.v.as_ptr(), out) })
    }

    /// A uniform scale by `k` about `centre`.
    pub fn scale(centre: [f64; 3], k: f64) -> Result<Transform> {
        Transform::made("transform_scale", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_scale)(centre.as_ptr(), k, out) })
    }

    /// A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.
    pub fn scale_xyz(frame: &Frame, sx: f64, sy: f64, sz: f64) -> Result<Transform> {
        Transform::made("transform_scale_xyz", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_scale_xyz)(frame.v.as_ptr(), sx, sy, sz, out) })
    }

    /// Every point slid along `direction` by `factor` times its height above `plane`.
    /// `direction` is normalised -- `factor` alone sets the slide -- and must lie in the plane.
    pub fn shear(plane: &Frame, direction: [f64; 3], factor: f64) -> Result<Transform> {
        Transform::made("transform_shear", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_shear)(plane.v.as_ptr(), direction.as_ptr(), factor, out) })
    }

    /// The rigid map sending frame `a` onto frame `b`.
    pub fn plane_to_plane(a: &Frame, b: &Frame) -> Result<Transform> {
        Transform::made("transform_plane_to_plane", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_plane_to_plane)(a.v.as_ptr(), b.v.as_ptr(), out) })
    }

    /// Coordinates in frame `from` to coordinates in frame `to`: a change of basis.
    pub fn change_basis(from: &Frame, to: &Frame) -> Result<Transform> {
        Transform::made("transform_change_basis", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_change_basis)(from.v.as_ptr(), to.v.as_ptr(), out) })
    }

    /// The orthogonal projection onto `plane` -- singular by design.
    pub fn planar_projection(plane: &Frame) -> Result<Transform> {
        Transform::made("transform_planar_projection", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_planar_projection)(plane.v.as_ptr(), out) })
    }

    /// The parallel projection onto `plane` along `direction`, which must not lie in it.
    pub fn project_along(plane: &Frame, direction: [f64; 3]) -> Result<Transform> {
        Transform::made("transform_project_along", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_project_along)(plane.v.as_ptr(), direction.as_ptr(), out) })
    }

    /// The 16 numbers, row-major.
    pub fn rows(&self) -> [f64; 16] {
        self.rows
    }

    /// Where the map takes the point `p`.
    pub fn point(&self, p: [f64; 3]) -> [f64; 3] {
        let ([x, y, z], r) = (p, &self.rows);
        [
            r[0] * x + r[1] * y + r[2] * z + r[3],
            r[4] * x + r[5] * y + r[6] * z + r[7],
            r[8] * x + r[9] * y + r[10] * z + r[11],
        ]
    }

    /// This map after `other`: `self.compose(&other).point(p) == self.point(other.point(p))`.
    /// The same as `self * other`.
    pub fn compose(&self, other: &Transform) -> Result<Transform> {
        Transform::made("transform_compose", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_compose)(self.rows.as_ptr(), other.rows.as_ptr(), out) })
    }

    /// The map undoing this one; refused for a singular map.
    pub fn inverse(&self) -> Result<Transform> {
        Transform::made("transform_inverse", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_inverse)(self.rows.as_ptr(), out) })
    }

    /// Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`, [`MAP_TOLERANCE`]
    /// in Python's default): a rotation or a mirror. Refused for a tolerance negative or not
    /// finite. [`Solid::transform`] is looser: it applies a map within 1e-6 of a similarity
    /// as that similarity.
    pub fn is_rigid(&self, tolerance: f64) -> Result<bool> {
        let api = api()?;
        match unsafe { (api.cadaclysm_blacksmith_transform_is_rigid)(self.rows.as_ptr(), tolerance) } {
            NONE => Err(fail(api, "transform_is_rigid")),
            told => Ok(told == 1),
        }
    }

    /// The scale `k` where the linear part is `k` times an orthogonal one (`AᵀA = k²I` to
    /// `tolerance`, relative to `k²`), else `None`. Refused for a tolerance negative or not finite.
    pub fn is_similarity(&self, tolerance: f64) -> Result<Option<f64>> {
        let api = api()?;
        let k = unsafe { (api.cadaclysm_blacksmith_transform_is_similarity)(self.rows.as_ptr(), tolerance) };
        if k.is_nan() {
            return Err(fail(api, "transform_is_similarity"));
        }
        Ok((k > 0.0).then_some(k))
    }

    /// The translation and the orthogonal part of a rigid map, else `None`.
    pub fn decompose_rigid(&self, tolerance: f64) -> Result<Option<RigidParts>> {
        if !self.is_rigid(tolerance)? {
            return Ok(None);
        }
        let out = written::<19>("transform_decompose_rigid", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_decompose_rigid)(self.rows.as_ptr(), tolerance, out) })?;
        Ok(Some(RigidParts { translation: [out[0], out[1], out[2]], orthogonal: Transform::from_rows(&out[3..19])? }))
    }

    /// The translation, the orthogonal part and the scale `k` of a similarity, else `None`.
    pub fn decompose_similarity(&self, tolerance: f64) -> Result<Option<SimilarityParts>> {
        if self.is_similarity(tolerance)?.is_none() {
            return Ok(None);
        }
        let out = written::<20>("transform_decompose_similarity", |api, out| unsafe { (api.cadaclysm_blacksmith_transform_decompose_similarity)(self.rows.as_ptr(), tolerance, out) })?;
        Ok(Some(SimilarityParts { translation: [out[0], out[1], out[2]], orthogonal: Transform::from_rows(&out[3..19])?, k: out[19] }))
    }

    /// The polar split of the map ([`AffineParts`]); `None` for a singular map or one
    /// stretched past 1e7:1, which has no unique split.
    pub fn decompose_affine(&self) -> Result<Option<AffineParts>> {
        let api = api()?;
        let mut out = [0.0; 38];
        if !unsafe { (api.cadaclysm_blacksmith_transform_decompose_affine)(self.rows.as_ptr(), out.as_mut_ptr()) } {
            return Ok(None);
        }
        Ok(Some(AffineParts {
            translation: [out[0], out[1], out[2]],
            rotation: Transform::from_rows(&out[3..19])?,
            axes: Transform::from_rows(&out[19..35])?,
            stretch: [out[35], out[36], out[37]],
        }))
    }
}

/// `a * b` is `a` after `b`: [`Transform::compose`], through the library, so a `Result`.
impl Mul for Transform {
    type Output = Result<Transform>;

    fn mul(self, other: Transform) -> Result<Transform> {
        self.compose(&other)
    }
}

/// A rotation as `w + xi + yj + zk`, a value. `q` and `-q` are the same rotation; a non-unit
/// one is normalised wherever it becomes a rotation, and a zero one is refused there. `a * b`
/// turns by `b`, then `a`. Equality is by components, so `q != -q`.
///
/// [`from_axis_angle`](Self::from_axis_angle), [`from_transform`](Self::from_transform),
/// [`slerp`](Self::slerp) and [`to_transform`](Self::to_transform) are the library's; the
/// rest is local arithmetic, scaled by the largest component as the library scales it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quaternion {
    q: [f64; 4],
}

impl Default for Quaternion {
    fn default() -> Quaternion {
        Quaternion::identity()
    }
}

/// The length of `vs`, scaled by its largest component first, as the library's
/// `quaternion_from` does: squaring 1e200 overflows and 1e-170 underflows.
fn scaled_norm(vs: &[f64]) -> f64 {
    let big = vs.iter().fold(0.0f64, |m, v| m.max(v.abs()));
    if big == 0.0 {
        return 0.0;
    }
    big * vs.iter().map(|v| (v / big) * (v / big)).sum::<f64>().sqrt()
}

impl Quaternion {
    /// `w + xi + yj + zk`; refused for a component not finite.
    pub fn new(w: f64, x: f64, y: f64, z: f64) -> Result<Quaternion> {
        let q = [w, x, y, z].map(|v| v + 0.0); // no -0.0 to print or compare
        if !q.iter().all(|v| v.is_finite()) {
            return Err(Error::new("Quaternion: not finite"));
        }
        Ok(Quaternion { q })
    }

    /// The turn that turns nothing, `1 + 0i + 0j + 0k`.
    pub fn identity() -> Quaternion {
        Quaternion { q: [1.0, 0.0, 0.0, 0.0] }
    }

    fn made(what: &str, call: impl FnOnce(&'static Api, *mut f64) -> bool) -> Result<Quaternion> {
        let [w, x, y, z] = written::<4>(what, call)?;
        Quaternion::new(w, x, y, z)
    }

    /// The turn of `radians` about `direction`, right-handed.
    pub fn from_axis_angle(direction: [f64; 3], radians: f64) -> Result<Quaternion> {
        Quaternion::made("quaternion_from_axis_angle", |api, out| unsafe { (api.cadaclysm_blacksmith_quaternion_from_axis_angle)(direction.as_ptr(), radians, out) })
    }

    /// The rotation in `t`'s linear part (its translation ignored); refused unless that is a
    /// proper rotation, orthogonal to 1e-9 -- take [`Transform::decompose_affine`]'s
    /// `rotation` first for a map rounded to float32.
    pub fn from_transform(t: &Transform) -> Result<Quaternion> {
        Quaternion::made("quaternion_from_transform", |api, out| unsafe { (api.cadaclysm_blacksmith_quaternion_from_transform)(t.rows.as_ptr(), out) })
    }

    /// From `a` (`s = 0`) to `b` (`s = 1`) along the shorter arc.
    pub fn slerp(a: &Quaternion, b: &Quaternion, s: f64) -> Result<Quaternion> {
        Quaternion::made("quaternion_slerp", |api, out| unsafe { (api.cadaclysm_blacksmith_quaternion_slerp)(a.q.as_ptr(), b.q.as_ptr(), s, out) })
    }

    /// This rotation as a [`Transform`] fixing `centre`; refused for a zero quaternion.
    pub fn to_transform(&self, centre: [f64; 3]) -> Result<Transform> {
        Transform::made("quaternion_to_transform", |api, out| unsafe { (api.cadaclysm_blacksmith_quaternion_to_transform)(self.q.as_ptr(), centre.as_ptr(), out) })
    }

    pub fn w(&self) -> f64 {
        self.q[0]
    }

    pub fn x(&self) -> f64 {
        self.q[1]
    }

    pub fn y(&self) -> f64 {
        self.q[2]
    }

    pub fn z(&self) -> f64 {
        self.q[3]
    }

    /// `[w, x, y, z]`.
    pub fn components(&self) -> [f64; 4] {
        self.q
    }

    /// Its length; 1 for a rotation as the library makes one.
    pub fn length(&self) -> f64 {
        scaled_norm(&self.q)
    }

    /// The turn, in `[0, 2π]`.
    pub fn angle(&self) -> f64 {
        2.0 * scaled_norm(&self.q[1..]).atan2(self.q[0])
    }

    /// The turn's axis, unit; `None` for the identity.
    pub fn axis(&self) -> Option<[f64; 3]> {
        let big = self.q[1..].iter().fold(0.0f64, |m, v| m.max(v.abs()));
        if big == 0.0 {
            return None;
        }
        let v = [self.q[1] / big, self.q[2] / big, self.q[3] / big];
        let n = dot(v, v).sqrt();
        Some(v.map(|c| c / n))
    }

    /// The opposite turn.
    pub fn conjugate(&self) -> Quaternion {
        Quaternion { q: [self.q[0], -self.q[1], -self.q[2], -self.q[3]].map(|v| v + 0.0) }
    }

    /// The same rotation at length 1, scaled by its largest component before the square root,
    /// so 1e200 and 1e-170 normalise. Refused for a zero quaternion.
    pub fn normalized(&self) -> Result<Quaternion> {
        let big = self.q.iter().fold(0.0f64, |m, v| m.max(v.abs()));
        if big == 0.0 {
            return Err(Error::new("Quaternion.normalized: the quaternion is zero"));
        }
        let v = self.q.map(|c| c / big);
        let n = v.iter().map(|c| c * c).sum::<f64>().sqrt();
        Quaternion::new(v[0] / n, v[1] / n, v[2] / n, v[3] / n)
    }
}

/// The Hamilton product: `a * b` turns by `b`, then `a`. A `Result` because a product of
/// huge components can overflow, which [`Quaternion::new`] refuses.
impl Mul for Quaternion {
    type Output = Result<Quaternion>;

    fn mul(self, o: Quaternion) -> Result<Quaternion> {
        let (a, b) = (self.q, o.q);
        Quaternion::new(
            a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
            a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
            a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
            a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
        )
    }
}

// ---- value geometry ------------------------------------------------------------------

/// A parameter range `t0..t1`, in either order: [`length`](Self::length) and
/// [`swapped`](Self::swapped) keep the order, the set operations ([`grown`](Self::grown),
/// [`union`](Self::union), [`intersect`](Self::intersect)) answer increasing. A value with
/// nothing to free, both ends finite; equality and hashing are by the two numbers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Interval {
    t: [f64; 2],
}

impl Eq for Interval {}

impl Hash for Interval {
    fn hash<H: Hasher>(&self, state: &mut H) {
        hash_numbers(&self.t, state);
    }
}

/// Hashes as `==` compares: `-0.0` and `0.0` alike (no value here holds a NaN).
fn hash_numbers<H: Hasher>(numbers: &[f64], state: &mut H) {
    for c in numbers {
        (c + 0.0).to_bits().hash(state);
    }
}

/// What the value constructors take for a range: an [`Interval`], or two numbers as a
/// pair `(t0, t1)` or an array `[t0, t1]` (refused where either is not finite).
pub trait IntervalLike {
    fn interval(self) -> Result<Interval>;
}

impl IntervalLike for Interval {
    fn interval(self) -> Result<Interval> {
        Ok(self)
    }
}

impl IntervalLike for (f64, f64) {
    fn interval(self) -> Result<Interval> {
        Interval::new(self.0, self.1)
    }
}

impl IntervalLike for [f64; 2] {
    fn interval(self) -> Result<Interval> {
        Interval::new(self[0], self[1])
    }
}

impl Interval {
    /// `t0..t1`, in either order; refused where either end is not finite.
    pub fn new(t0: f64, t1: f64) -> Result<Interval> {
        if !(t0.is_finite() && t1.is_finite()) {
            return Err(Error::new("Interval: not finite"));
        }
        Ok(Interval::of_finite(t0, t1))
    }

    /// An [`Interval`], or two numbers as a pair or an array, as an `Interval`.
    pub fn of(value: impl IntervalLike) -> Result<Interval> {
        value.interval()
    }

    /// Two numbers known finite (a canonical value's, or a min/max of finite ones).
    fn of_finite(t0: f64, t1: f64) -> Interval {
        Interval { t: [t0 + 0.0, t1 + 0.0] } // no -0.0 to print or compare
    }

    pub fn t0(&self) -> f64 {
        self.t[0]
    }

    pub fn t1(&self) -> f64 {
        self.t[1]
    }

    /// `[t0, t1]`.
    pub fn values(&self) -> [f64; 2] {
        self.t
    }

    /// `t1 - t0`: negative for a decreasing interval.
    pub fn length(&self) -> f64 {
        self.t[1] - self.t[0]
    }

    pub fn mid(&self) -> f64 {
        0.5 * (self.t[0] + self.t[1])
    }

    pub fn min(&self) -> f64 {
        self.t[0].min(self.t[1])
    }

    pub fn max(&self) -> f64 {
        self.t[0].max(self.t[1])
    }

    pub fn is_increasing(&self) -> bool {
        self.t[0] < self.t[1]
    }

    pub fn is_singleton(&self) -> bool {
        self.t[0] == self.t[1]
    }

    /// `t1..t0`.
    pub fn swapped(&self) -> Interval {
        Interval { t: [self.t[1], self.t[0]] }
    }

    /// The increasing interval holding this one and `t`; refused for an infinite `t`.
    pub fn grown(&self, t: f64) -> Result<Interval> {
        Interval::new(self.min().min(t), self.max().max(t))
    }

    /// The increasing interval holding both.
    pub fn union(&self, other: Interval) -> Interval {
        Interval::of_finite(self.min().min(other.min()), self.max().max(other.max()))
    }

    /// The increasing overlap, `None` where the two are apart; touching is a singleton.
    pub fn intersect(&self, other: Interval) -> Option<Interval> {
        let (t0, t1) = (self.min().max(other.min()), self.max().min(other.max()));
        (t0 <= t1).then(|| Interval::of_finite(t0, t1))
    }

    /// Whether `t` lies in the closed range, either order.
    pub fn contains(&self, t: f64) -> bool {
        self.min() <= t && t <= self.max()
    }

    /// `t0 + s (t1 - t0)`: the fraction `s` of the way from `t0` (outside `0..1` extrapolates).
    pub fn parameter_at(&self, s: f64) -> f64 {
        self.t[0] + s * (self.t[1] - self.t[0])
    }

    /// The fraction `t` sits from `t0` toward `t1`; `None` for a singleton.
    pub fn normalized_parameter_at(&self, t: f64) -> Option<f64> {
        let length = self.length();
        (length != 0.0).then(|| (t - self.t[0]) / length)
    }
}

/// The closest point of a curve value ([`Line::closest_point`] and the others): its
/// parameter `t`, the `point`, and `unique` -- false where the answer is a fixed pick among
/// equals (a point on a circle's axis, an arc's two equidistant ends).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CurveFoot {
    pub t: f64,
    pub point: [f64; 3],
    pub unique: bool,
}

/// The closest point of a surface value ([`Sphere::closest_point`] and the others): its
/// parameters `u`, `v`, the `point`, and `unique` (false where the answer is a pick among
/// equals: a sphere's centre, a point on an axis).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceFoot {
    pub u: f64,
    pub v: f64,
    pub point: [f64; 3],
    pub unique: bool,
}

/// The tolerance [`Sphere::contains`] and the other shapes' `contains` take by default
/// in the other wrappers.
pub const CONTAINS_TOLERANCE: f64 = 1e-9;

/// `values` as a value of `kind`, squared up by the library's `value_check`: refused for
/// the wrong count (in the library's own sentence, by `value_size`) or a bad value.
fn checked_value<const N: usize>(kind: u32, name: &str, values: &[f64]) -> Result<[f64; N]> {
    let api = api()?;
    let size = unsafe { (api.cadaclysm_blacksmith_value_size)(kind) } as usize;
    if values.len() != size {
        return Err(Error::new(format!("value_check: a {name} is {size} numbers, got {}", values.len())));
    }
    if size != N {
        return Err(Error::new(format!("value_check: this library's {name} is {size} numbers, this crate's {N}")));
    }
    let mut out = [0.0; N];
    if !unsafe { (api.cadaclysm_blacksmith_value_check)(kind, values.as_ptr(), out.as_mut_ptr()) } {
        return Err(fail(api, "value_check"));
    }
    Ok(out)
}

fn value_bounds(kind: u32, v: &[f64]) -> Result<([f64; 3], [f64; 3])> {
    let b = written::<6>("value_bounds", |api, out| unsafe { (api.cadaclysm_blacksmith_value_bounds)(kind, v.as_ptr(), out) })?;
    Ok(([b[0], b[1], b[2]], [b[3], b[4], b[5]]))
}

fn value_transform<const N: usize>(kind: u32, v: &[f64; N], t: &Transform) -> Result<[f64; N]> {
    written::<N>("value_transform", |api, out| unsafe { (api.cadaclysm_blacksmith_value_transform)(kind, v.as_ptr(), t.rows.as_ptr(), out) })
}

fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    let d = [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    dot(d, d).sqrt()
}

fn first_frame(v: &[f64]) -> Frame {
    let mut f = [0.0; 12];
    f.copy_from_slice(&v[..12]);
    Frame { v: f }
}

fn on_frame(frame: &Frame, rest: &[f64]) -> Vec<f64> {
    frame.v.iter().chain(rest).copied().collect()
}

fn curve_point_at(kind: u32, v: &[f64], t: f64) -> Result<[f64; 3]> {
    written::<3>("curve_value_point_at", |api, out| unsafe { (api.cadaclysm_blacksmith_curve_value_point_at)(kind, v.as_ptr(), t, out) })
}

fn curve_tangent_at(kind: u32, v: &[f64], t: f64) -> Result<[f64; 3]> {
    written::<3>("curve_value_tangent_at", |api, out| unsafe { (api.cadaclysm_blacksmith_curve_value_tangent_at)(kind, v.as_ptr(), t, out) })
}

fn curve_length(kind: u32, v: &[f64]) -> Result<f64> {
    Ok(written::<1>("curve_value_length", |api, out| unsafe { (api.cadaclysm_blacksmith_curve_value_length)(kind, v.as_ptr(), out) })?[0])
}

fn curve_closest_point(kind: u32, v: &[f64], p: [f64; 3]) -> Result<CurveFoot> {
    let f = written::<5>("curve_value_closest_point", |api, out| unsafe { (api.cadaclysm_blacksmith_curve_value_closest_point)(kind, v.as_ptr(), p.as_ptr(), out) })?;
    Ok(CurveFoot { t: f[0], point: [f[1], f[2], f[3]], unique: f[4] != 0.0 })
}

fn surface_closest_point(kind: u32, v: &[f64], p: [f64; 3]) -> Result<SurfaceFoot> {
    let f = written::<6>("surface_value_closest_point", |api, out| unsafe { (api.cadaclysm_blacksmith_surface_value_closest_point)(kind, v.as_ptr(), p.as_ptr(), out) })?;
    Ok(SurfaceFoot { u: f[0], v: f[1], point: [f[2], f[3], f[4]], unique: f[5] != 0.0 })
}

fn surface_point_at(kind: u32, v: &[f64], u: f64, w: f64) -> Result<[f64; 3]> {
    written::<3>("surface_value_point_at", |api, out| unsafe { (api.cadaclysm_blacksmith_surface_value_point_at)(kind, v.as_ptr(), u, w, out) })
}

fn surface_normal_at(kind: u32, v: &[f64], u: f64, w: f64) -> Result<[f64; 3]> {
    written::<3>("surface_value_normal_at", |api, out| unsafe { (api.cadaclysm_blacksmith_surface_value_normal_at)(kind, v.as_ptr(), u, w, out) })
}

fn surface_domain(kind: u32, v: &[f64]) -> Result<(Interval, Interval)> {
    let d = written::<4>("surface_value_domain", |api, out| unsafe { (api.cadaclysm_blacksmith_surface_value_domain)(kind, v.as_ptr(), out) })?;
    Ok((Interval::of_finite(d[0], d[1]), Interval::of_finite(d[2], d[3])))
}

fn surface_nurbs_sheet(kind: u32, v: &[f64]) -> Result<Solid> {
    let api = api()?;
    Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_surface_value_nurbs_sheet)(kind, v.as_ptr()) }, "surface_value_nurbs_sheet")
}

fn solid_contains(kind: u32, v: &[f64], p: [f64; 3], tolerance: f64) -> Result<bool> {
    let api = api()?;
    match unsafe { (api.cadaclysm_blacksmith_solid_value_contains)(kind, v.as_ptr(), p.as_ptr(), tolerance) } {
        NONE => Err(fail(api, "solid_value_contains")),
        told => Ok(told != 0),
    }
}

fn solid_area(kind: u32, v: &[f64]) -> Result<f64> {
    Ok(written::<1>("solid_value_area", |api, out| unsafe { (api.cadaclysm_blacksmith_solid_value_area)(kind, v.as_ptr(), out) })?[0])
}

fn solid_volume(kind: u32, v: &[f64]) -> Result<f64> {
    Ok(written::<1>("solid_value_volume", |api, out| unsafe { (api.cadaclysm_blacksmith_solid_value_volume)(kind, v.as_ptr(), out) })?[0])
}

fn solid_to_solid(kind: u32, v: &[f64]) -> Result<Solid> {
    let api = api()?;
    Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_solid_value_to_solid)(kind, v.as_ptr()) }, "solid_value_to_solid")
}

/// Equality and hashing for a value type: each type its own, so a circle and a sphere never
/// compare, and the kind enters the hash with the array.
macro_rules! value_traits {
    ($name:ident) => {
        impl Eq for $name {}

        impl Hash for $name {
            fn hash<H: Hasher>(&self, state: &mut H) {
                $name::KIND.hash(state);
                hash_numbers(&self.v, state);
            }
        }
    };
}

/// The segment from `start` to `end`; its parameter runs 0..1. A value with nothing to free,
/// its array `from[3] to[3]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Line {
    v: [f64; 6],
}

impl Line {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_LINE;

    /// A line from its raw array of 6 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Line> {
        Ok(Line { v: checked_value::<6>(Line::KIND, "line", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 6] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Line::KIND, &self.v)
    }

    /// This line under `t`, a value of the same type: any map that keeps its ends apart.
    pub fn transform(&self, t: &Transform) -> Result<Line> {
        Ok(Line { v: value_transform(Line::KIND, &self.v, t)? })
    }

    /// The point at `t`: the fraction `t` of the way from `start` to `end` (0..1 spans the segment).
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_point_at(Line::KIND, &self.v, t)
    }

    /// The unit tangent at `t`, the way `t` grows.
    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_tangent_at(Line::KIND, &self.v, t)
    }

    /// The length.
    pub fn length(&self) -> Result<f64> {
        curve_length(Line::KIND, &self.v)
    }

    /// The [`CurveFoot`] nearest `p`, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        curve_closest_point(Line::KIND, &self.v, p)
    }

    /// How far `p` lies from the curve.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }
}

value_traits!(Line);

impl Line {
    /// The exact NURBS form of this curve.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        curve_to_nurbs(Line::KIND, &self.v)
    }
}

impl Line {
    /// Refused for two equal ends.
    pub fn new(start: [f64; 3], end: [f64; 3]) -> Result<Line> {
        Line::from_values(&[start[0], start[1], start[2], end[0], end[1], end[2]])
    }

    pub fn start(&self) -> [f64; 3] {
        [self.v[0], self.v[1], self.v[2]]
    }

    pub fn end(&self) -> [f64; 3] {
        [self.v[3], self.v[4], self.v[5]]
    }
}

/// The circle of `radius` about the frame's origin in its x-y plane, counter-clockwise
/// about its z, from its x. Its array is `frame[12] radius`.
///
/// Each value type is its own, so a circle and a sphere of the same numbers never compare:
///
/// ```compile_fail
/// # use cadaclysm_sdk::blacksmith::{Circle, Frame, Sphere};
/// let frame = Frame::xy([0.0; 3]);
/// let same = Circle::new(&frame, 2.0).unwrap() == Sphere::new(&frame, 2.0).unwrap(); // error: no such comparison
/// ```
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Circle {
    v: [f64; 13],
}

impl Circle {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_CIRCLE;

    /// A circle from its raw array of 13 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Circle> {
        Ok(Circle { v: checked_value::<13>(Circle::KIND, "circle", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 13] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Circle::KIND, &self.v)
    }

    /// This circle under `t`, a value of the same type: only a similarity ([`Ellipse::from_circle`] first for
    /// any other map).
    pub fn transform(&self, t: &Transform) -> Result<Circle> {
        Ok(Circle { v: value_transform(Circle::KIND, &self.v, t)? })
    }

    /// The point at `t`: `t` the angle in radians from the frame's x toward its y.
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_point_at(Circle::KIND, &self.v, t)
    }

    /// The unit tangent at `t`, the way `t` grows.
    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_tangent_at(Circle::KIND, &self.v, t)
    }

    /// The length.
    pub fn length(&self) -> Result<f64> {
        curve_length(Circle::KIND, &self.v)
    }

    /// The [`CurveFoot`] nearest `p`, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        curve_closest_point(Circle::KIND, &self.v, p)
    }

    /// How far `p` lies from the curve.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The frame the circle lies on: its centre, the x its angles start from, its normal.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }
}

value_traits!(Circle);

impl Circle {
    /// The exact NURBS form of this curve.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        curve_to_nurbs(Circle::KIND, &self.v)
    }
}

impl Circle {
    pub fn new(frame: &Frame, radius: f64) -> Result<Circle> {
        Circle::from_values(&on_frame(frame, &[radius]))
    }

    /// The circle through three points, x toward `a`, turning `a`, `b`, `c` counter-clockwise.
    pub fn through(a: [f64; 3], b: [f64; 3], c: [f64; 3]) -> Result<Circle> {
        Ok(Circle { v: written::<13>("circle_through", |api, out| unsafe { (api.cadaclysm_blacksmith_circle_through)(a.as_ptr(), b.as_ptr(), c.as_ptr(), out) })? })
    }

    pub fn radius(&self) -> f64 {
        self.v[12]
    }
}

/// The part of a circle over `angle`, increasing by at most a full turn. Its array is
/// `frame[12] radius t0 t1`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Arc {
    v: [f64; 15],
}

impl Arc {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_ARC;

    /// An arc from its raw array of 15 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Arc> {
        Ok(Arc { v: checked_value::<15>(Arc::KIND, "arc", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 15] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Arc::KIND, &self.v)
    }

    /// This arc under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Arc> {
        Ok(Arc { v: value_transform(Arc::KIND, &self.v, t)? })
    }

    /// The point at `t`: `t` the angle in radians from the frame's x toward its y.
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_point_at(Arc::KIND, &self.v, t)
    }

    /// The unit tangent at `t`, the way `t` grows.
    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_tangent_at(Arc::KIND, &self.v, t)
    }

    /// The length.
    pub fn length(&self) -> Result<f64> {
        curve_length(Arc::KIND, &self.v)
    }

    /// The [`CurveFoot`] nearest `p`, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        curve_closest_point(Arc::KIND, &self.v, p)
    }

    /// How far `p` lies from the curve.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The frame the arc lies on: its centre, the x its angles start from, its normal.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }
}

value_traits!(Arc);

impl Arc {
    /// The exact NURBS form of this curve.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        curve_to_nurbs(Arc::KIND, &self.v)
    }
}

impl Arc {
    /// `angle` an [`Interval`] or a pair.
    pub fn new(frame: &Frame, radius: f64, angle: impl IntervalLike) -> Result<Arc> {
        let a = angle.interval()?;
        Arc::from_values(&on_frame(frame, &[radius, a.t0(), a.t1()]))
    }

    /// The arc from `a` through `b` to `c`.
    pub fn through(a: [f64; 3], b: [f64; 3], c: [f64; 3]) -> Result<Arc> {
        Ok(Arc { v: written::<15>("arc_through", |api, out| unsafe { (api.cadaclysm_blacksmith_arc_through)(a.as_ptr(), b.as_ptr(), c.as_ptr(), out) })? })
    }

    /// The arc leaving `a` along `tangent` and ending at `c`.
    pub fn from_start_tangent_end(a: [f64; 3], tangent: [f64; 3], c: [f64; 3]) -> Result<Arc> {
        Ok(Arc {
            v: written::<15>("arc_from_start_tangent_end", |api, out| unsafe {
                (api.cadaclysm_blacksmith_arc_from_start_tangent_end)(a.as_ptr(), tangent.as_ptr(), c.as_ptr(), out)
            })?,
        })
    }

    pub fn radius(&self) -> f64 {
        self.v[12]
    }

    pub fn angle(&self) -> Interval {
        Interval::of_finite(self.v[13], self.v[14])
    }

    /// The point at the angle's start.
    pub fn start(&self) -> Result<[f64; 3]> {
        self.point_at(self.v[13])
    }

    /// The point at the angle's end.
    pub fn end(&self) -> Result<[f64; 3]> {
        self.point_at(self.v[14])
    }

    /// The point halfway along.
    pub fn mid(&self) -> Result<[f64; 3]> {
        self.point_at(0.5 * (self.v[13] + self.v[14]))
    }
}

/// The ellipse of radius `r1` along the frame's x and `r2` along its y. Its array is
/// `frame[12] r1 r2`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ellipse {
    v: [f64; 14],
}

impl Ellipse {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_ELLIPSE;

    /// An ellipse from its raw array of 14 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Ellipse> {
        Ok(Ellipse { v: checked_value::<14>(Ellipse::KIND, "ellipse", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 14] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Ellipse::KIND, &self.v)
    }

    /// This ellipse under `t`, a value of the same type: any map that keeps it an ellipse.
    pub fn transform(&self, t: &Transform) -> Result<Ellipse> {
        Ok(Ellipse { v: value_transform(Ellipse::KIND, &self.v, t)? })
    }

    /// The point at `t`: `t` the eccentric angle in radians, from the frame's x toward its y.
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_point_at(Ellipse::KIND, &self.v, t)
    }

    /// The unit tangent at `t`, the way `t` grows.
    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_tangent_at(Ellipse::KIND, &self.v, t)
    }

    /// The perimeter, in closed form.
    pub fn length(&self) -> Result<f64> {
        curve_length(Ellipse::KIND, &self.v)
    }

    /// The [`CurveFoot`] nearest `p`, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        curve_closest_point(Ellipse::KIND, &self.v, p)
    }

    /// How far `p` lies from the curve.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The frame the ellipse lies on: its centre, its first axis, its normal.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }
}

value_traits!(Ellipse);

impl Ellipse {
    /// The exact NURBS form of this curve.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        curve_to_nurbs(Ellipse::KIND, &self.v)
    }
}

impl Ellipse {
    pub fn new(frame: &Frame, r1: f64, r2: f64) -> Result<Ellipse> {
        Ellipse::from_values(&on_frame(frame, &[r1, r2]))
    }

    /// `circle` as an ellipse of two equal radii -- which takes any map that keeps it one.
    pub fn from_circle(circle: &Circle) -> Result<Ellipse> {
        Ok(Ellipse { v: written::<14>("ellipse_from_circle", |api, out| unsafe { (api.cadaclysm_blacksmith_ellipse_from_circle)(circle.v.as_ptr(), out) })? })
    }

    pub fn r1(&self) -> f64 {
        self.v[12]
    }

    pub fn r2(&self) -> f64 {
        self.v[13]
    }
}

/// The sphere of `radius` about the frame's origin; `u` the longitude from its x, `v` the
/// latitude toward its z. Its array is `frame[12] radius`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sphere {
    v: [f64; 13],
}

impl Sphere {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_SPHERE;

    /// A sphere from its raw array of 13 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Sphere> {
        Ok(Sphere { v: checked_value::<13>(Sphere::KIND, "sphere", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 13] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Sphere::KIND, &self.v)
    }

    /// This sphere under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Sphere> {
        Ok(Sphere { v: value_transform(Sphere::KIND, &self.v, t)? })
    }

    /// The frame the shape is placed on: its origin and axes.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it
    /// ([`CONTAINS_TOLERANCE`] is the other wrappers' default). NaN is unset, the shape's own
    /// effective tolerance (`tolerance.relative` times its diagonal); 0 is exact. Refused for a
    /// tolerance negative or infinite.
    pub fn contains(&self, p: [f64; 3], tolerance: f64) -> Result<bool> {
        solid_contains(Sphere::KIND, &self.v, p, tolerance)
    }

    /// The boundary's area, in closed form.
    pub fn area(&self) -> Result<f64> {
        solid_area(Sphere::KIND, &self.v)
    }

    /// The volume enclosed, in closed form.
    pub fn volume(&self) -> Result<f64> {
        solid_volume(Sphere::KIND, &self.v)
    }

    /// The shape as a closed exact B-rep solid.
    pub fn to_solid(&self) -> Result<Solid> {
        solid_to_solid(Sphere::KIND, &self.v)
    }

    /// The point at `(u, v)`, in the ranges [`domain`](Self::domain) gives.
    pub fn point_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_point_at(Sphere::KIND, &self.v, u, v)
    }

    /// The outward unit normal at `(u, v)`.
    pub fn normal_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_normal_at(Sphere::KIND, &self.v, u, v)
    }

    /// The [`SurfaceFoot`] nearest `p` on the surface, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<SurfaceFoot> {
        surface_closest_point(Sphere::KIND, &self.v, p)
    }

    /// How far `p` lies from the surface.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The `u` and `v` ranges.
    pub fn domain(&self) -> Result<(Interval, Interval)> {
        surface_domain(Sphere::KIND, &self.v)
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    pub fn to_nurbs_sheet(&self) -> Result<Solid> {
        surface_nurbs_sheet(Sphere::KIND, &self.v)
    }
}

value_traits!(Sphere);

impl Sphere {
    pub fn new(frame: &Frame, radius: f64) -> Result<Sphere> {
        Sphere::from_values(&on_frame(frame, &[radius]))
    }

    pub fn radius(&self) -> f64 {
        self.v[12]
    }
}

/// The cylinder of `radius` about the frame's z over `height` (increasing, along z), capped.
/// Its array is `frame[12] radius h0 h1`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cylinder {
    v: [f64; 15],
}

impl Cylinder {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_CYLINDER;

    /// A cylinder from its raw array of 15 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Cylinder> {
        Ok(Cylinder { v: checked_value::<15>(Cylinder::KIND, "cylinder", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 15] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Cylinder::KIND, &self.v)
    }

    /// This cylinder under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Cylinder> {
        Ok(Cylinder { v: value_transform(Cylinder::KIND, &self.v, t)? })
    }

    /// The frame the shape is placed on: its origin and axes.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it
    /// ([`CONTAINS_TOLERANCE`] is the other wrappers' default). NaN is unset, the shape's own
    /// effective tolerance (`tolerance.relative` times its diagonal); 0 is exact. Refused for a
    /// tolerance negative or infinite.
    pub fn contains(&self, p: [f64; 3], tolerance: f64) -> Result<bool> {
        solid_contains(Cylinder::KIND, &self.v, p, tolerance)
    }

    /// The boundary's area, in closed form: the caps included.
    pub fn area(&self) -> Result<f64> {
        solid_area(Cylinder::KIND, &self.v)
    }

    /// The volume enclosed, in closed form.
    pub fn volume(&self) -> Result<f64> {
        solid_volume(Cylinder::KIND, &self.v)
    }

    /// The shape as a closed exact B-rep solid.
    pub fn to_solid(&self) -> Result<Solid> {
        solid_to_solid(Cylinder::KIND, &self.v)
    }

    /// The point at `(u, v)`, in the ranges [`domain`](Self::domain) gives.
    pub fn point_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_point_at(Cylinder::KIND, &self.v, u, v)
    }

    /// The outward unit normal at `(u, v)`.
    pub fn normal_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_normal_at(Cylinder::KIND, &self.v, u, v)
    }

    /// The [`SurfaceFoot`] nearest `p` on the surface (the side, not the caps), in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<SurfaceFoot> {
        surface_closest_point(Cylinder::KIND, &self.v, p)
    }

    /// How far `p` lies from the surface.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The `u` and `v` ranges.
    pub fn domain(&self) -> Result<(Interval, Interval)> {
        surface_domain(Cylinder::KIND, &self.v)
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    pub fn to_nurbs_sheet(&self) -> Result<Solid> {
        surface_nurbs_sheet(Cylinder::KIND, &self.v)
    }
}

value_traits!(Cylinder);

impl Cylinder {
    /// `height` an [`Interval`] or a pair.
    pub fn new(frame: &Frame, radius: f64, height: impl IntervalLike) -> Result<Cylinder> {
        let h = height.interval()?;
        Cylinder::from_values(&on_frame(frame, &[radius, h.t0(), h.t1()]))
    }

    pub fn radius(&self) -> f64 {
        self.v[12]
    }

    pub fn height(&self) -> Interval {
        Interval::of_finite(self.v[13], self.v[14])
    }
}

/// The cone of base `radius` on the frame's x-y plane, its apex `height` up its z, capped.
/// Its array is `frame[12] radius height`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cone {
    v: [f64; 14],
}

impl Cone {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_CONE;

    /// A cone from its raw array of 14 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Cone> {
        Ok(Cone { v: checked_value::<14>(Cone::KIND, "cone", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 14] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Cone::KIND, &self.v)
    }

    /// This cone under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Cone> {
        Ok(Cone { v: value_transform(Cone::KIND, &self.v, t)? })
    }

    /// The frame the shape is placed on: its origin and axes.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it
    /// ([`CONTAINS_TOLERANCE`] is the other wrappers' default). NaN is unset, the shape's own
    /// effective tolerance (`tolerance.relative` times its diagonal); 0 is exact. Refused for a
    /// tolerance negative or infinite.
    pub fn contains(&self, p: [f64; 3], tolerance: f64) -> Result<bool> {
        solid_contains(Cone::KIND, &self.v, p, tolerance)
    }

    /// The boundary's area, in closed form: the caps included.
    pub fn area(&self) -> Result<f64> {
        solid_area(Cone::KIND, &self.v)
    }

    /// The volume enclosed, in closed form.
    pub fn volume(&self) -> Result<f64> {
        solid_volume(Cone::KIND, &self.v)
    }

    /// The shape as a closed exact B-rep solid.
    pub fn to_solid(&self) -> Result<Solid> {
        solid_to_solid(Cone::KIND, &self.v)
    }

    /// The point at `(u, v)`, in the ranges [`domain`](Self::domain) gives.
    pub fn point_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_point_at(Cone::KIND, &self.v, u, v)
    }

    /// The outward unit normal at `(u, v)`.
    pub fn normal_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_normal_at(Cone::KIND, &self.v, u, v)
    }

    /// The [`SurfaceFoot`] nearest `p` on the surface (the side, not the caps), in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<SurfaceFoot> {
        surface_closest_point(Cone::KIND, &self.v, p)
    }

    /// How far `p` lies from the surface.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The `u` and `v` ranges.
    pub fn domain(&self) -> Result<(Interval, Interval)> {
        surface_domain(Cone::KIND, &self.v)
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    pub fn to_nurbs_sheet(&self) -> Result<Solid> {
        surface_nurbs_sheet(Cone::KIND, &self.v)
    }
}

value_traits!(Cone);

impl Cone {
    pub fn new(frame: &Frame, radius: f64, height: f64) -> Result<Cone> {
        Cone::from_values(&on_frame(frame, &[radius, height]))
    }

    pub fn radius(&self) -> f64 {
        self.v[12]
    }

    pub fn height(&self) -> f64 {
        self.v[13]
    }
}

/// The torus of `major` radius about the frame's z and `minor` radius about that circle.
/// Its array is `frame[12] major minor`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Torus {
    v: [f64; 14],
}

impl Torus {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_TORUS;

    /// A torus from its raw array of 14 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Torus> {
        Ok(Torus { v: checked_value::<14>(Torus::KIND, "torus", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 14] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Torus::KIND, &self.v)
    }

    /// This torus under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Torus> {
        Ok(Torus { v: value_transform(Torus::KIND, &self.v, t)? })
    }

    /// The frame the shape is placed on: its origin and axes.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it
    /// ([`CONTAINS_TOLERANCE`] is the other wrappers' default). NaN is unset, the shape's own
    /// effective tolerance (`tolerance.relative` times its diagonal); 0 is exact. Refused for a
    /// tolerance negative or infinite.
    pub fn contains(&self, p: [f64; 3], tolerance: f64) -> Result<bool> {
        solid_contains(Torus::KIND, &self.v, p, tolerance)
    }

    /// The boundary's area, in closed form.
    pub fn area(&self) -> Result<f64> {
        solid_area(Torus::KIND, &self.v)
    }

    /// The volume enclosed, in closed form.
    pub fn volume(&self) -> Result<f64> {
        solid_volume(Torus::KIND, &self.v)
    }

    /// The shape as a closed exact B-rep solid.
    pub fn to_solid(&self) -> Result<Solid> {
        solid_to_solid(Torus::KIND, &self.v)
    }

    /// The point at `(u, v)`, in the ranges [`domain`](Self::domain) gives.
    pub fn point_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_point_at(Torus::KIND, &self.v, u, v)
    }

    /// The outward unit normal at `(u, v)`.
    pub fn normal_at(&self, u: f64, v: f64) -> Result<[f64; 3]> {
        surface_normal_at(Torus::KIND, &self.v, u, v)
    }

    /// The [`SurfaceFoot`] nearest `p` on the surface, in closed form.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<SurfaceFoot> {
        surface_closest_point(Torus::KIND, &self.v, p)
    }

    /// How far `p` lies from the surface.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The `u` and `v` ranges.
    pub fn domain(&self) -> Result<(Interval, Interval)> {
        surface_domain(Torus::KIND, &self.v)
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    pub fn to_nurbs_sheet(&self) -> Result<Solid> {
        surface_nurbs_sheet(Torus::KIND, &self.v)
    }
}

value_traits!(Torus);

impl Torus {
    pub fn new(frame: &Frame, major: f64, minor: f64) -> Result<Torus> {
        Torus::from_values(&on_frame(frame, &[major, minor]))
    }

    pub fn major(&self) -> f64 {
        self.v[12]
    }

    pub fn minor(&self) -> f64 {
        self.v[13]
    }
}

/// The box over `x`, `y`, `z` (increasing ranges) along its frame's axes. Its array is
/// `frame[12] x0 x1 y0 y1 z0 z1`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cuboid {
    v: [f64; 18],
}

impl Cuboid {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_CUBOID;

    /// A cuboid from its raw array of 18 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Cuboid> {
        Ok(Cuboid { v: checked_value::<18>(Cuboid::KIND, "cuboid", values)? })
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 18] {
        self.v
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Cuboid::KIND, &self.v)
    }

    /// This cuboid under `t`, a value of the same type: only a similarity.
    pub fn transform(&self, t: &Transform) -> Result<Cuboid> {
        Ok(Cuboid { v: value_transform(Cuboid::KIND, &self.v, t)? })
    }

    /// The frame the shape is placed on: its origin and axes.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it
    /// ([`CONTAINS_TOLERANCE`] is the other wrappers' default). NaN is unset, the shape's own
    /// effective tolerance (`tolerance.relative` times its diagonal); 0 is exact. Refused for a
    /// tolerance negative or infinite.
    pub fn contains(&self, p: [f64; 3], tolerance: f64) -> Result<bool> {
        solid_contains(Cuboid::KIND, &self.v, p, tolerance)
    }

    /// The boundary's area, in closed form.
    pub fn area(&self) -> Result<f64> {
        solid_area(Cuboid::KIND, &self.v)
    }

    /// The volume enclosed, in closed form.
    pub fn volume(&self) -> Result<f64> {
        solid_volume(Cuboid::KIND, &self.v)
    }

    /// The shape as a closed exact B-rep solid.
    pub fn to_solid(&self) -> Result<Solid> {
        solid_to_solid(Cuboid::KIND, &self.v)
    }
}

value_traits!(Cuboid);

impl Cuboid {
    /// Each range an [`Interval`] or a pair.
    pub fn new(frame: &Frame, x: impl IntervalLike, y: impl IntervalLike, z: impl IntervalLike) -> Result<Cuboid> {
        let (x, y, z) = (x.interval()?, y.interval()?, z.interval()?);
        Cuboid::from_values(&on_frame(frame, &[x.t0(), x.t1(), y.t0(), y.t1(), z.t0(), z.t1()]))
    }

    /// The world-aligned box from `min` to `max`.
    pub fn from_bounds(min: [f64; 3], max: [f64; 3]) -> Result<Cuboid> {
        Ok(Cuboid { v: written::<18>("cuboid_from_bounds", |api, out| unsafe { (api.cadaclysm_blacksmith_cuboid_from_bounds)(min.as_ptr(), max.as_ptr(), out) })? })
    }

    /// The tightest box holding `points`, aligned to `frame`.
    pub fn around(frame: &Frame, points: &[[f64; 3]]) -> Result<Cuboid> {
        let xyz: Vec<f64> = points.iter().flatten().copied().collect();
        Ok(Cuboid {
            v: written::<18>("cuboid_around", |api, out| unsafe { (api.cadaclysm_blacksmith_cuboid_around)(frame.v.as_ptr(), xyz.as_ptr(), points.len(), out) })?,
        })
    }

    pub fn x(&self) -> Interval {
        Interval::of_finite(self.v[12], self.v[13])
    }

    pub fn y(&self) -> Interval {
        Interval::of_finite(self.v[14], self.v[15])
    }

    pub fn z(&self) -> Interval {
        Interval::of_finite(self.v[16], self.v[17])
    }

    /// The eight corners: the `z0` face counter-clockwise about +z from `(x0, y0)`, then the
    /// `z1` face in the same order.
    pub fn corners(&self) -> Result<[[f64; 3]; 8]> {
        let c = written::<24>("cuboid_corners", |api, out| unsafe { (api.cadaclysm_blacksmith_cuboid_corners)(self.v.as_ptr(), out) })?;
        Ok(std::array::from_fn(|k| [c[3 * k], c[3 * k + 1], c[3 * k + 2]]))
    }

    /// The point the fractions `sx`, `sy`, `sz` of the way along each range.
    pub fn point_at(&self, sx: f64, sy: f64, sz: f64) -> Result<[f64; 3]> {
        written::<3>("cuboid_point_at", |api, out| unsafe { (api.cadaclysm_blacksmith_cuboid_point_at)(self.v.as_ptr(), sx, sy, sz, out) })
    }

    /// The closest point of the solid box: `p` itself inside.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<[f64; 3]> {
        written::<3>("cuboid_closest_point", |api, out| unsafe { (api.cadaclysm_blacksmith_cuboid_closest_point)(self.v.as_ptr(), p.as_ptr(), out) })
    }
}

/// The rectangle over `x` and `y` (increasing ranges) in its frame's x-y plane. As a curve it
/// is its boundary: `t` runs 0..4, one unit a side from corner `(x0, y0)` counter-clockwise
/// about the frame's z, clamped outside that range; [`Rectangle::closest_point`] is the
/// boundary's, not unique on a tie (the centre). Its array is `frame[12] x0 x1 y0 y1`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rectangle {
    v: [f64; 16],
}

impl Rectangle {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_RECTANGLE;

    /// A rectangle from its raw array of 16 numbers, checked and squared up by the library:
    /// refused for another count or a bad value.
    pub fn from_values(values: &[f64]) -> Result<Rectangle> {
        Ok(Rectangle { v: checked_value::<16>(Rectangle::KIND, "rectangle", values)? })
    }

    /// Each range an [`Interval`] or a pair.
    pub fn new(frame: &Frame, x: impl IntervalLike, y: impl IntervalLike) -> Result<Rectangle> {
        let (x, y) = (x.interval()?, y.interval()?);
        Rectangle::from_values(&on_frame(frame, &[x.t0(), x.t1(), y.t0(), y.t1()]))
    }

    /// The canonical array, as the library squared it up.
    pub fn values(&self) -> [f64; 16] {
        self.v
    }

    /// The frame the rectangle lies on: its ranges run along the frame's x and y.
    pub fn frame(&self) -> Frame {
        first_frame(&self.v)
    }

    pub fn x(&self) -> Interval {
        Interval::of_finite(self.v[12], self.v[13])
    }

    pub fn y(&self) -> Interval {
        Interval::of_finite(self.v[14], self.v[15])
    }

    /// The world box of the four corners, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Rectangle::KIND, &self.v)
    }

    /// This rectangle under `t`: any map keeping its sides square (no shear in its plane).
    pub fn transform(&self, t: &Transform) -> Result<Rectangle> {
        Ok(Rectangle { v: value_transform(Rectangle::KIND, &self.v, t)? })
    }

    /// The boundary's point at `t`: side `k` for `t` in `k..k+1`, clamped outside 0..4.
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_point_at(Rectangle::KIND, &self.v, t)
    }

    /// The unit direction of `t`'s side.
    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        curve_tangent_at(Rectangle::KIND, &self.v, t)
    }

    /// The boundary's length, the circumference.
    pub fn length(&self) -> Result<f64> {
        curve_length(Rectangle::KIND, &self.v)
    }

    /// The [`CurveFoot`] on the boundary nearest `p` (projected onto the plane first).
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        curve_closest_point(Rectangle::KIND, &self.v, p)
    }

    /// How far `p` lies from the boundary.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The four corners: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`.
    pub fn corners(&self) -> Result<[[f64; 3]; 4]> {
        let c = written::<12>("rectangle_corners", |api, out| unsafe { (api.cadaclysm_blacksmith_rectangle_corners)(self.v.as_ptr(), out) })?;
        Ok(std::array::from_fn(|k| [c[3 * k], c[3 * k + 1], c[3 * k + 2]]))
    }

    /// The filled rectangle's area.
    pub fn area(&self) -> Result<f64> {
        Ok(written::<1>("rectangle_area", |api, out| unsafe { (api.cadaclysm_blacksmith_rectangle_area)(self.v.as_ptr(), out) })?[0])
    }

    /// `p` projected onto the plane and clamped into the filled rectangle when
    /// `include_interior` (the other wrappers' default), else the boundary's closest point.
    pub fn closest_point_in(&self, p: [f64; 3], include_interior: bool) -> Result<[f64; 3]> {
        written::<3>("rectangle_closest_point", |api, out| unsafe {
            (api.cadaclysm_blacksmith_rectangle_closest_point)(self.v.as_ptr(), p.as_ptr(), include_interior, out)
        })
    }

    /// Where `p`, projected onto the plane, lies: `"inside"`, `"outside"`, or `"on"` within
    /// `tolerance` of the boundary. `None` (or NaN) is unset, the rectangle's own effective
    /// tolerance (`tolerance.relative` times its diagonal); `Some(0.0)` is exact.
    pub fn contains(&self, p: [f64; 3], tolerance: Option<f64>) -> Result<&'static str> {
        let api = api()?;
        match unsafe { (api.cadaclysm_blacksmith_rectangle_contains)(self.v.as_ptr(), p.as_ptr(), tolerance.unwrap_or(f64::NAN)) } {
            NONE => Err(fail(api, "rectangle_contains")),
            code => containment("rectangle_contains", code),
        }
    }

    /// The filled rectangle as a one-face planar sheet facing the frame's z.
    pub fn to_sheet(&self) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_rectangle_to_sheet)(self.v.as_ptr()) }, "rectangle_to_sheet")
    }

    /// The boundary as its exact closed degree-1 NURBS curve, a knot at each corner, so its
    /// parameter is `t`.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        curve_to_nurbs(Rectangle::KIND, &self.v)
    }
}

value_traits!(Rectangle);

/// The triangle `a`, `b`, `c`; a degenerate one (collinear or coincident points) is refused.
/// Its array is `a[3] b[3] c[3]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Triangle {
    v: [f64; 9],
}

impl Triangle {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_TRIANGLE;

    /// A triangle from its raw array of 9 numbers, checked by the library: refused for another
    /// count or a degenerate triangle.
    pub fn from_values(values: &[f64]) -> Result<Triangle> {
        Ok(Triangle { v: checked_value::<9>(Triangle::KIND, "triangle", values)? })
    }

    pub fn new(a: [f64; 3], b: [f64; 3], c: [f64; 3]) -> Result<Triangle> {
        Triangle::from_values(&[a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]])
    }

    /// The canonical array.
    pub fn values(&self) -> [f64; 9] {
        self.v
    }

    pub fn a(&self) -> [f64; 3] {
        [self.v[0], self.v[1], self.v[2]]
    }

    pub fn b(&self) -> [f64; 3] {
        [self.v[3], self.v[4], self.v[5]]
    }

    pub fn c(&self) -> [f64; 3] {
        [self.v[6], self.v[7], self.v[8]]
    }

    /// The world box of the three vertices, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Triangle::KIND, &self.v)
    }

    /// This triangle under `t`: any affine map keeping it a triangle.
    pub fn transform(&self, t: &Transform) -> Result<Triangle> {
        Ok(Triangle { v: value_transform(Triangle::KIND, &self.v, t)? })
    }

    pub fn area(&self) -> Result<f64> {
        Ok(written::<1>("triangle_area", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_area)(self.v.as_ptr(), out) })?[0])
    }

    /// The sum of the three sides.
    pub fn perimeter(&self) -> Result<f64> {
        Ok(written::<1>("triangle_perimeter", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_perimeter)(self.v.as_ptr(), out) })?[0])
    }

    /// The area centroid, the vertices' mean.
    pub fn centroid(&self) -> Result<[f64; 3]> {
        written::<3>("triangle_centroid", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_centroid)(self.v.as_ptr(), out) })
    }

    /// The circle through `a`, `b` and `c`: its x toward `a`, turning them counter-clockwise.
    pub fn circumcircle(&self) -> Result<Circle> {
        Ok(Circle { v: written::<13>("triangle_circumcircle", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_circumcircle)(self.v.as_ptr(), out) })? })
    }

    /// The point of barycentric weights `wa`, `wb`, `wc`, used as given.
    pub fn point_at(&self, wa: f64, wb: f64, wc: f64) -> Result<[f64; 3]> {
        written::<3>("triangle_point_at", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_point_at)(self.v.as_ptr(), wa, wb, wc, out) })
    }

    /// The weights `[wa, wb, wc]`, summing to 1, of `p` projected onto the plane.
    pub fn barycentric(&self, p: [f64; 3]) -> Result<[f64; 3]> {
        written::<3>("triangle_barycentric", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_barycentric)(self.v.as_ptr(), p.as_ptr(), out) })
    }

    /// The closest point of the filled triangle to `p`, exact.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<[f64; 3]> {
        written::<3>("triangle_closest_point", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_closest_point)(self.v.as_ptr(), p.as_ptr(), out) })
    }

    /// How far `p` lies from the filled triangle.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?, p))
    }

    /// Edge `i` as a line: 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`.
    pub fn edge(&self, i: u32) -> Result<Line> {
        Ok(Line { v: written::<6>("triangle_edge", |api, out| unsafe { (api.cadaclysm_blacksmith_triangle_edge)(self.v.as_ptr(), i, out) })? })
    }

    /// The filled triangle as a one-face planar sheet, its normal turning `a`, `b`, `c`
    /// counter-clockwise.
    pub fn to_sheet(&self) -> Result<Solid> {
        let api = api()?;
        Solid::wrap(api, unsafe { (api.cadaclysm_blacksmith_triangle_to_sheet)(self.v.as_ptr()) }, "triangle_to_sheet")
    }
}

value_traits!(Triangle);

/// The half-line from `position` along `direction`. The direction is kept as given, not
/// unitised, so `t` counts lengths of it. A ray has no box: [`Ray::bounds`] is the library's
/// refusal. Its array is `position[3] direction[3]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ray {
    v: [f64; 6],
}

impl Ray {
    /// The kind its array is tagged with.
    pub const KIND: u32 = sys::CADACLYSM_BLACKSMITH_VALUE_RAY;

    /// A ray from its raw array of 6 numbers, checked by the library: refused for another
    /// count or a zero direction.
    pub fn from_values(values: &[f64]) -> Result<Ray> {
        Ok(Ray { v: checked_value::<6>(Ray::KIND, "ray", values)? })
    }

    pub fn new(position: [f64; 3], direction: [f64; 3]) -> Result<Ray> {
        Ray::from_values(&[position[0], position[1], position[2], direction[0], direction[1], direction[2]])
    }

    /// The canonical array.
    pub fn values(&self) -> [f64; 6] {
        self.v
    }

    pub fn position(&self) -> [f64; 3] {
        [self.v[0], self.v[1], self.v[2]]
    }

    pub fn direction(&self) -> [f64; 3] {
        [self.v[3], self.v[4], self.v[5]]
    }

    /// The library's refusal: a ray has no box.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        value_bounds(Ray::KIND, &self.v)
    }

    /// This ray under `t`: any affine map keeping its direction.
    pub fn transform(&self, t: &Transform) -> Result<Ray> {
        Ok(Ray { v: value_transform(Ray::KIND, &self.v, t)? })
    }

    /// `position + t * direction`, any `t` (behind the start too).
    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        written::<3>("ray_point_at", |api, out| unsafe { (api.cadaclysm_blacksmith_ray_point_at)(self.v.as_ptr(), t, out) })
    }

    /// The [`CurveFoot`] on the ray nearest `p`: `t` clamped at 0, so a point behind the start
    /// answers the start. Always unique.
    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        let f = written::<4>("ray_closest_point", |api, out| unsafe { (api.cadaclysm_blacksmith_ray_closest_point)(self.v.as_ptr(), p.as_ptr(), out) })?;
        Ok(CurveFoot { t: f[0], point: [f[1], f[2], f[3]], unique: true })
    }

    /// How far `p` lies from the ray.
    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }
}

value_traits!(Ray);

/// A curve value of any kind: what [`Curve::value`] gives an edge's line, circle, arc or
/// ellipse, or a [`Rectangle`]'s boundary. Equality and hashing are the value's own, so two
/// kinds never compare equal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CurveValue {
    Line(Line),
    Circle(Circle),
    Arc(Arc),
    Ellipse(Ellipse),
    Rectangle(Rectangle),
}

impl CurveValue {
    fn parts(&self) -> (u32, &[f64]) {
        match self {
            CurveValue::Line(c) => (Line::KIND, &c.v),
            CurveValue::Circle(c) => (Circle::KIND, &c.v),
            CurveValue::Arc(c) => (Arc::KIND, &c.v),
            CurveValue::Ellipse(c) => (Ellipse::KIND, &c.v),
            CurveValue::Rectangle(c) => (Rectangle::KIND, &c.v),
        }
    }

    /// The kind its array is tagged with (`CADACLYSM_BLACKSMITH_VALUE_*`).
    pub fn kind(&self) -> u32 {
        self.parts().0
    }

    /// The canonical array.
    pub fn values(&self) -> Vec<f64> {
        self.parts().1.to_vec()
    }

    pub fn point_at(&self, t: f64) -> Result<[f64; 3]> {
        let (kind, v) = self.parts();
        curve_point_at(kind, v, t)
    }

    pub fn tangent_at(&self, t: f64) -> Result<[f64; 3]> {
        let (kind, v) = self.parts();
        curve_tangent_at(kind, v, t)
    }

    pub fn length(&self) -> Result<f64> {
        let (kind, v) = self.parts();
        curve_length(kind, v)
    }

    pub fn closest_point(&self, p: [f64; 3]) -> Result<CurveFoot> {
        let (kind, v) = self.parts();
        curve_closest_point(kind, v, p)
    }

    pub fn distance_to(&self, p: [f64; 3]) -> Result<f64> {
        Ok(distance(self.closest_point(p)?.point, p))
    }

    /// The world box, `(min, max)`.
    pub fn bounds(&self) -> Result<([f64; 3], [f64; 3])> {
        let (kind, v) = self.parts();
        value_bounds(kind, v)
    }

    /// The exact NURBS form of this curve.
    pub fn to_nurbs(&self) -> Result<NurbsCurve> {
        let (kind, v) = self.parts();
        curve_to_nurbs(kind, v)
    }

    /// This curve under `t`, of the same kind.
    pub fn transform(&self, t: &Transform) -> Result<CurveValue> {
        Ok(match self {
            CurveValue::Line(c) => CurveValue::Line(c.transform(t)?),
            CurveValue::Circle(c) => CurveValue::Circle(c.transform(t)?),
            CurveValue::Arc(c) => CurveValue::Arc(c.transform(t)?),
            CurveValue::Ellipse(c) => CurveValue::Ellipse(c.transform(t)?),
            CurveValue::Rectangle(c) => CurveValue::Rectangle(c.transform(t)?),
        })
    }
}

impl From<Line> for CurveValue {
    fn from(c: Line) -> CurveValue {
        CurveValue::Line(c)
    }
}

impl From<Circle> for CurveValue {
    fn from(c: Circle) -> CurveValue {
        CurveValue::Circle(c)
    }
}

impl From<Arc> for CurveValue {
    fn from(c: Arc) -> CurveValue {
        CurveValue::Arc(c)
    }
}

impl From<Ellipse> for CurveValue {
    fn from(c: Ellipse) -> CurveValue {
        CurveValue::Ellipse(c)
    }
}

impl From<Rectangle> for CurveValue {
    fn from(c: Rectangle) -> CurveValue {
        CurveValue::Rectangle(c)
    }
}

/// Which surfaces [`Solid::convert_to_nurbs`] rewrites as their exact NURBS.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NurbsLevel {
    /// The revolutions, extrusions and sums.
    Procedural,
    /// Those and the cylinders, cones, spheres and tori: every curved face.
    Analytic,
    /// Everything, planes and edge curves too: a body made only of NURBS.
    #[default]
    All,
}

impl NurbsLevel {
    fn code(self) -> u32 {
        match self {
            NurbsLevel::Procedural => sys::CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL,
            NurbsLevel::Analytic => sys::CADACLYSM_BLACKSMITH_NURBS_ANALYTIC,
            NurbsLevel::All => sys::CADACLYSM_BLACKSMITH_NURBS_ALL,
        }
    }
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

    /// A regular polygon of `sides` sides (at least 3) whose sides touch the circle of
    /// `radius` about `centre` -- the polygon across flats, a nut's hex: its corners on the
    /// circle of `radius / cos(pi / sides)`, the first at `angle` radians from the sketch's x
    /// axis, the rest counter-clockwise, on the same rays as [`Profile::regular_polygon`]'s
    /// corners for the same `angle`; each side's midpoint on the circle of `radius`.
    pub fn circumscribed_polygon(centre: [f64; 2], radius: f64, sides: u32, angle: f64) -> Result<Profile> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_profile_circumscribed_polygon)(centre[0], centre[1], radius, sides, angle) };
        Profile::wrap(api, raw, "profile_circumscribed_polygon")
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

    /// This outline turned `radians` (counter-clockwise) about `centre`.
    pub fn rotate(&self, centre: [f64; 2], radians: f64) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_rotate)(self.raw(), centre[0], centre[1], radians) };
        Profile::wrap(self.api, raw, "profile_rotate")
    }

    /// This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the two are
    /// equal in size, and becomes exact conics otherwise. A negative factor mirrors; a zero one
    /// is singular and refused.
    pub fn scale(&self, centre: [f64; 2], sx: f64, sy: f64) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_scale)(self.raw(), centre[0], centre[1], sx, sy) };
        Profile::wrap(self.api, raw, "profile_scale")
    }

    /// This outline reflected across the line through `point` along `direction`; a zero
    /// `direction` is refused.
    pub fn mirror(&self, point: [f64; 2], direction: [f64; 2]) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_mirror)(self.raw(), point[0], point[1], direction[0], direction[1]) };
        Profile::wrap(self.api, raw, "profile_mirror")
    }

    /// This outline under the 2D affine map `m`, six numbers row-major (2×3):
    /// `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`. A singular map is refused.
    pub fn transform2d(&self, m: [f64; 6]) -> Result<Profile> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_transform2d)(self.raw(), m.as_ptr()) };
        Profile::wrap(self.api, raw, "profile_transform2d")
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

    /// This profile as the `path` field of a `profile.path` document node holds it, as JSON
    /// text: its exact segments (lines, arcs, Beziers, conics, NURBS), holes and colour,
    /// `{"start", "segments", "holes", "colour"}`. How [`Document::add_profile`] puts a
    /// profile in a document, drawn as it was.
    pub fn document_path(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_profile_path)(self.raw()) }, "document_profile_path")
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
    /// This curve as a value: a line [`Line`] from `origin` to `origin + x`; a circle a
    /// [`Circle`] over a full turn, else the [`Arc`] over `t0..t1`; an ellipse its whole
    /// [`Ellipse`] (the range stays here: there is no elliptical-arc value); any other kind
    /// `None`.
    pub fn value(&self) -> Result<Option<CurveValue>> {
        let frame: Vec<f64> = self.origin.iter().chain(&self.x).chain(&self.y).chain(&self.z).copied().collect();
        let with = |rest: &[f64]| -> Vec<f64> { frame.iter().chain(rest).copied().collect() };
        let (o, x) = (self.origin, self.x);
        Ok(Some(match self.kind.as_str() {
            "line" => CurveValue::Line(Line::new(o, [o[0] + x[0], o[1] + x[1], o[2] + x[2]])?),
            "circle" if self.t1 - self.t0 >= 2.0 * std::f64::consts::PI - 1e-12 => CurveValue::Circle(Circle::from_values(&with(&[self.radius]))?),
            "circle" => CurveValue::Arc(Arc::from_values(&with(&[self.radius, self.t0, self.t1]))?),
            "ellipse" => CurveValue::Ellipse(Ellipse::from_values(&with(&[self.radius, self.radius2]))?),
            _ => return Ok(None),
        }))
    }

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
/// partial overlap of curved faces whose outlines cross.
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

/// An intersection handle read out into an [`Intersection`] and freed, on every path (a failed
/// read's too) -- [`Solid::intersect`]'s reader, and [`Clash::intersect`]'s.
///
/// # Safety
/// `found` a live intersection from this library, not used again after this call.
unsafe fn intersection_of(api: &Api, found: *mut sys::CadaclysmBlacksmithIntersection) -> Result<Intersection> {
    let read = || {
        let count = unsafe { (api.cadaclysm_blacksmith_intersection_chain_count)(found) };
        let mut chains = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut raw = sys::CadaclysmBlacksmithChain::default();
            if !unsafe { (api.cadaclysm_blacksmith_intersection_chain)(found, i, &mut raw) } {
                return Err(fail(api, "intersection_chain"));
            }
            let curve = if raw.has_curve {
                let mut raw_curve = sys::CadaclysmBlacksmithCurve::default();
                if !unsafe { (api.cadaclysm_blacksmith_intersection_curve)(found, i, &mut raw_curve) } {
                    return Err(fail(api, "intersection_curve"));
                }
                // SAFETY: the curve's arrays live in the result until it is freed below.
                Some(unsafe { Curve::from_raw(&raw_curve) })
            } else {
                None
            };
            // SAFETY: as above; everything is copied out before the free.
            chains.push(unsafe { Chain::from_raw(&raw, curve) });
        }
        let count = unsafe { (api.cadaclysm_blacksmith_intersection_overlap_count)(found) };
        let mut overlaps = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut raw = sys::CadaclysmBlacksmithOverlap::default();
            if !unsafe { (api.cadaclysm_blacksmith_intersection_overlap)(found, i, &mut raw) } {
                return Err(fail(api, "intersection_overlap"));
            }
            // SAFETY: as above.
            overlaps.push(unsafe { Overlap::from_raw(&raw) });
        }
        Ok(Intersection { chains, overlaps })
    };
    // Read everything, then free on every path, a failed read's too.
    let result = read();
    unsafe { (api.cadaclysm_blacksmith_intersection_free)(found) };
    result
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

/// A solid's box on its principal axes ([`Solid::oriented_box`]). Not minimal: where two
/// moments of inertia are equal (a sphere, a cube) the axes are a free choice. The `half`
/// extents are grown by the tolerance the measurement settled on.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct OrientedBox {
    /// The middle of the box, which is not the centroid.
    pub centre: [f64; 3],
    /// Row-major: row `i` is the unit direction of the extent `half[i]`; right-handed.
    pub axes: [[f64; 3]; 3],
    pub half: [f64; 3],
}

/// A measured length beside the error it carries ([`Solid::edge_length`], [`Profile::length`]).
/// `error` is an estimate of the difference from the true length, not a proof.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Length {
    pub length: f64,
    pub error: f64,
    /// The refinement reached the accuracy asked for.
    pub accuracy_met: bool,
    /// The curve was a sampled polyline: exact for its points, not for what they sample.
    pub from_polyline: bool,
}

impl From<sys::CadaclysmBlacksmithLength> for Length {
    fn from(r: sys::CadaclysmBlacksmithLength) -> Length {
        Length { length: r.length, error: r.error, accuracy_met: r.accuracy_met != 0, from_polyline: r.from_polyline != 0 }
    }
}

/// A point on an edge or a profile's outer loop at a distance along it
/// ([`Solid::edge_point_at_length`], [`Profile::point_at_length`] and the divides): the
/// `point`, the unit `tangent`, the curve's own `parameter`, and the `error` estimate of the
/// arc length. `segment` is the side of a profile, `None` on a solid's edge.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct At {
    pub point: [f64; 3],
    pub tangent: [f64; 3],
    pub parameter: f64,
    pub segment: Option<u32>,
    pub error: f64,
    /// The curve was a sampled polyline: exact for its points, not for what they sample.
    pub from_polyline: bool,
}

impl From<sys::CadaclysmBlacksmithAt> for At {
    fn from(r: sys::CadaclysmBlacksmithAt) -> At {
        At {
            point: r.point,
            tangent: r.tangent,
            parameter: r.parameter,
            segment: (r.segment != NONE).then_some(r.segment),
            error: r.error,
            from_polyline: r.from_polyline != 0,
        }
    }
}

/// Frees a divide's sample list on every exit.
struct SamplesGuard {
    raw: *mut sys::CadaclysmBlacksmithSamples,
    api: &'static Api,
}

impl Drop for SamplesGuard {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_samples_free)(self.raw) };
    }
}

/// The samples of a list the library handed back (null: the last error), copied out; the
/// list is freed on every path, a failing read's too (its reason read first).
fn samples_of(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSamples, what: &str) -> Result<Vec<At>> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let list = SamplesGuard { raw, api };
    let count = unsafe { (api.cadaclysm_blacksmith_samples_count)(list.raw) };
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut at = sys::CadaclysmBlacksmithAt::default();
        if !unsafe { (api.cadaclysm_blacksmith_samples_at)(list.raw, i, &mut at) } {
            // `fail` runs before `list` drops, so the reason is read before the free.
            return Err(fail(api, "samples_at"));
        }
        out.push(at.into());
    }
    Ok(out)
}

// ---- NurbsCurve: curves in space ----------------------------------------------------

/// The tolerance [`NurbsCurve::fit`], [`NurbsCurve::projected_to_face`],
/// [`NurbsCurve::pulled_to_face`] and [`NurbsCurve::face_hits`] are usually given: pass it as
/// `Some(NURBS_CURVE_TOLERANCE)`. `None` (or 0 or NaN) asks for the inputs' effective tolerance.
pub const NURBS_CURVE_TOLERANCE: f64 = 1e-3;

/// A curve's bending at a parameter ([`NurbsCurve::curvature`]): `kappa` (1 / radius), the unit
/// `tangent`, the unit `normal` toward the centre and the `binormal` (`tangent x normal`), and
/// the `centre` of the osculating circle -- `None` on a straight piece, where `kappa` is 0 and
/// `normal`, `binormal` are zero.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Curvature {
    pub kappa: f64,
    pub tangent: [f64; 3],
    pub normal: [f64; 3],
    pub binormal: [f64; 3],
    pub centre: Option<[f64; 3]>,
}

impl From<sys::CadaclysmBlacksmithCurvature> for Curvature {
    fn from(r: sys::CadaclysmBlacksmithCurvature) -> Curvature {
        Curvature {
            kappa: r.kappa,
            tangent: r.tangent,
            normal: r.normal,
            binormal: r.binormal,
            centre: (r.has_centre != 0).then_some(r.centre),
        }
    }
}

/// How [`NurbsCurve::tween`] blends two curves (Rhino's CreateTweenCurves family).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TweenMethod {
    /// Control point by control point; the curves must already share one structure (degree,
    /// control-point count, knots).
    Plain,
    /// The curves made compatible exactly (degree elevation, knot merging), then blended in
    /// homogeneous coordinates -- rational curves stay rational.
    Matching,
    /// Both divided by arc length into `samples` pieces (required here, refused otherwise), and
    /// a cubic interpolated through the blended samples.
    Sampling,
}

impl TweenMethod {
    fn code(self) -> u32 {
        match self {
            TweenMethod::Plain => 0,
            TweenMethod::Matching => 1,
            TweenMethod::Sampling => 2,
        }
    }

    /// The method named `"plain"`, `"matching"` or `"sampling"`; another word is refused.
    pub fn parse(name: &str) -> Result<TweenMethod> {
        match name {
            "plain" => Ok(TweenMethod::Plain),
            "matching" => Ok(TweenMethod::Matching),
            "sampling" => Ok(TweenMethod::Sampling),
            other => Err(Error::new(format!("nurbs_curve_tween: method must be one of plain, matching, sampling, not '{other}'"))),
        }
    }
}

/// `points` as the flat C array of three doubles each.
fn flat_points(points: &[[f64; 3]]) -> Vec<f64> {
    points.iter().flatten().copied().collect()
}

/// An optional vector as the C ABI's pointer: NULL for none.
fn opt_ptr(v: &Option<[f64; 3]>) -> *const f64 {
    v.as_ref().map_or(ptr::null(), |v| v.as_ptr())
}

/// A tolerance as the library takes it: NaN (the inputs' effective tolerance) for none.
fn tol_arg(tolerance: Option<f64>) -> f64 {
    tolerance.unwrap_or(f64::NAN)
}

/// A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational one --
/// to model with: built through points, read off an edge or a face, projected onto a plane or a
/// face, trimmed, extended and blended; asked for its points, derivatives, curvature, length and
/// crossings. Immutable: every edit returns a new curve. Dropping it frees it; [`Clone`] is the
/// library's `nurbs_curve_clone`.
///
/// A face here is its whole surface: projecting onto, pulling to and crossing a face ignore its
/// trims. The `fit_error` is set only on curves from [`fit`](Self::fit),
/// [`projected_to_face`](Self::projected_to_face) and [`pulled_to_face`](Self::pulled_to_face).
pub struct NurbsCurve {
    handle: NonNull<sys::CadaclysmBlacksmithNurbsCurve>,
    api: &'static Api,
    fit_error: Option<f64>,
}

// Immutable once built, and the library's curve owns its data outright (as `Profile` does).
unsafe impl Send for NurbsCurve {}
unsafe impl Sync for NurbsCurve {}

impl Drop for NurbsCurve {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for NurbsCurve {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "NurbsCurve({:p})", self.handle)
    }
}

impl Clone for NurbsCurve {
    /// A copy of this curve (the library's `nurbs_curve_clone`).
    fn clone(&self) -> NurbsCurve {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_clone)(self.raw()) };
        let mut copy = NurbsCurve::wrap(self.api, raw, "nurbs_curve_clone").unwrap_or_else(|e| panic!("{e}"));
        copy.fit_error = self.fit_error;
        copy
    }
}

impl NurbsCurve {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithNurbsCurve, what: &str) -> Result<NurbsCurve> {
        NonNull::new(raw).map(|handle| NurbsCurve { handle, api, fit_error: None }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithNurbsCurve {
        self.handle.as_ptr()
    }

    /// A curve with the `fit_error` the library wrote (the three calls that fit).
    fn fitted(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithNurbsCurve, error: f64, what: &str) -> Result<NurbsCurve> {
        let mut curve = NurbsCurve::wrap(api, raw, what)?;
        curve.fit_error = Some(error);
        Ok(curve)
    }

    // ---- building ---------------------------------------------------------------------

    /// The curve with control points `points`, of `degree` (1 to 7), `weights` one per point
    /// (positive) or `None`, and the full knot vector `knots` (`points.len() + degree + 1`
    /// values, non-decreasing) or `None` for clamped and uniform.
    pub fn new(points: &[[f64; 3]], degree: u32, weights: Option<&[f64]>, knots: Option<&[f64]>) -> Result<NurbsCurve> {
        let api = api()?;
        if let Some(w) = weights {
            if w.len() != points.len() {
                return Err(Error::new(format!("nurbs_curve_new: {} weights for {} points; give one per point", w.len(), points.len())));
            }
        }
        let xyz = flat_points(points);
        let raw = unsafe {
            (api.cadaclysm_blacksmith_nurbs_curve_new)(
                xyz.as_ptr(),
                points.len(),
                weights.map_or(ptr::null(), |w| w.as_ptr()),
                degree,
                knots.map_or(ptr::null(), |k| k.as_ptr()),
                knots.map_or(0, |k| k.len()),
            )
        };
        NurbsCurve::wrap(api, raw, "nurbs_curve_new")
    }

    /// The curve of `degree` (1 to 7) through `points` in order, chord-length parametrised.
    /// `closed` closes it back to the first point, smooth across the seam; an open curve may
    /// leave along `start_tangent` and arrive along `end_tangent` (directions; their length does
    /// not matter).
    pub fn through(points: &[[f64; 3]], degree: u32, closed: bool, start_tangent: Option<[f64; 3]>, end_tangent: Option<[f64; 3]>) -> Result<NurbsCurve> {
        let api = api()?;
        let xyz = flat_points(points);
        let raw = unsafe {
            (api.cadaclysm_blacksmith_nurbs_curve_through)(xyz.as_ptr(), points.len(), degree, closed, opt_ptr(&start_tangent), opt_ptr(&end_tangent))
        };
        NurbsCurve::wrap(api, raw, "nurbs_curve_through")
    }

    /// A curve of `degree` within `tolerance` of every point, through the first and the last
    /// (least squares); its [`fit_error`](Self::fit_error) is the largest distance from a point
    /// to it. `None` asks for the inputs' effective tolerance; see [`NURBS_CURVE_TOLERANCE`].
    pub fn fit(points: &[[f64; 3]], degree: u32, tolerance: Option<f64>) -> Result<NurbsCurve> {
        let api = api()?;
        let xyz = flat_points(points);
        let mut error = 0.0;
        let raw = unsafe { (api.cadaclysm_blacksmith_nurbs_curve_fit)(xyz.as_ptr(), points.len(), degree, tol_arg(tolerance), &mut error) };
        NurbsCurve::fitted(api, raw, error, "nurbs_curve_fit")
    }

    /// Edge `edge` (an [`Edge::index`]) of `solid` as an exact NURBS over the edge's own span of
    /// its curve, running the way the edge runs.
    pub fn from_edge(solid: &Solid, edge: u32) -> Result<NurbsCurve> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_nurbs_curve_from_edge)(solid.raw(), edge) };
        NurbsCurve::wrap(api, raw, "nurbs_curve_from_edge")
    }

    /// The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `along_u`,
    /// else along `v` at `u = at`. NURBS faces only.
    pub fn isocurve(solid: &Solid, face: u32, along_u: bool, at: f64) -> Result<NurbsCurve> {
        let api = api()?;
        let raw = unsafe { (api.cadaclysm_blacksmith_nurbs_curve_from_face_isocurve)(solid.raw(), face, along_u, at) };
        NurbsCurve::wrap(api, raw, "nurbs_curve_from_face_isocurve")
    }

    /// The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end when
    /// `b_end`, else its start): `continuity` 1 matches position and tangent (a cubic), 2 also
    /// the curvature (a quintic; the usual choice); `bulge` (positive, usually 1) scales how far
    /// the tangents reach.
    pub fn blend(a: &NurbsCurve, a_end: bool, b: &NurbsCurve, b_end: bool, continuity: u32, bulge: f64) -> Result<NurbsCurve> {
        let raw = unsafe { (a.api.cadaclysm_blacksmith_nurbs_curve_blend)(a.raw(), a_end, b.raw(), b_end, continuity, bulge) };
        NurbsCurve::wrap(a.api, raw, "nurbs_curve_blend")
    }

    /// `curves` joined end to end into one curve (Rhino's JoinCurves): in the order given, each
    /// turned where needed so its start meets the previous one's end within `tolerance` (usually
    /// `1e-6`; the joint placed at the midpoint of the two ends). All are raised to the highest
    /// degree among them and each runs over `k..k + 1`, joined C0 -- a corner stays a corner; a
    /// rational curve keeps its points. One curve gives a copy; none, or a gap past `tolerance`,
    /// is refused naming the two curves.
    pub fn joined(curves: &[&NurbsCurve], tolerance: f64) -> Result<NurbsCurve> {
        let api = api()?;
        let handles: Vec<*const sys::CadaclysmBlacksmithNurbsCurve> = curves.iter().map(|c| c.raw()).collect();
        let raw = unsafe { (api.cadaclysm_blacksmith_nurbs_curve_joined)(handles.as_ptr(), handles.len(), tolerance) };
        NurbsCurve::wrap(api, raw, "nurbs_curve_joined")
    }

    /// `count` curves blending evenly from this curve to `other` (Rhino's CreateTweenCurves
    /// family), tween `i` at the fraction `(i + 1) / (count + 1)`. `samples` is required by
    /// [`TweenMethod::Sampling`] and refused for the others. `align` turns `other`, and moves a
    /// closed curve's seam, to line it up with this one first. `tolerance` `None`: the inputs'
    /// effective tolerance. A count of 0, one curve closed and the other open, plain on curves
    /// that are not compatible, or too few samples is refused.
    pub fn tween(&self, other: &NurbsCurve, count: u32, method: TweenMethod, samples: Option<u32>, align: bool, tolerance: Option<f64>) -> Result<Vec<NurbsCurve>> {
        match (method, samples) {
            (TweenMethod::Sampling, None) => return Err(Error::new("nurbs_curve_tween: sampling needs samples")),
            (TweenMethod::Plain, Some(_)) => return Err(Error::new("nurbs_curve_tween: samples is read only by sampling, not plain")),
            (TweenMethod::Matching, Some(_)) => return Err(Error::new("nurbs_curve_tween: samples is read only by sampling, not matching")),
            _ => {}
        }
        let mut out: Vec<*mut sys::CadaclysmBlacksmithNurbsCurve> = vec![ptr::null_mut(); (count as usize).max(1)];
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_nurbs_curve_tween)(self.raw(), other.raw(), count, method.code(), samples.unwrap_or(0), align, tol_arg(tolerance), out.as_mut_ptr())
        };
        if !ok {
            return Err(fail(self.api, "nurbs_curve_tween"));
        }
        // Wrap every handle first, so each is freed whatever the others do.
        let wrapped: Vec<Result<NurbsCurve>> = out.iter().take(count as usize).map(|&raw| NurbsCurve::wrap(self.api, raw, "nurbs_curve_tween")).collect();
        wrapped.into_iter().collect()
    }

    // ---- edits ------------------------------------------------------------------------

    /// This curve projected onto the plane through `origin` with `normal`, along `direction`
    /// (`None`: the normal). Exact.
    pub fn projected_to_plane(&self, origin: [f64; 3], normal: [f64; 3], direction: Option<[f64; 3]>) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_projected_to_plane)(self.raw(), origin.as_ptr(), normal.as_ptr(), opt_ptr(&direction)) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_projected_to_plane")
    }

    /// This curve projected along `direction` onto face `face` of `solid` (its whole surface),
    /// fitted within `tolerance`; the result's [`fit_error`](Self::fit_error) is the largest
    /// distance between it and the surface. Refused where a point's ray misses.
    pub fn projected_to_face(&self, solid: &Solid, face: u32, direction: [f64; 3], tolerance: Option<f64>) -> Result<NurbsCurve> {
        let mut error = 0.0;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_nurbs_curve_projected_to_face)(self.raw(), solid.raw(), face, direction.as_ptr(), tol_arg(tolerance), &mut error)
        };
        NurbsCurve::fitted(self.api, raw, error, "nurbs_curve_projected_to_face")
    }

    /// This curve pulled onto face `face` of `solid` (its whole surface): every point to its
    /// nearest surface point, fitted within `tolerance` (`fit_error` as for the projection).
    pub fn pulled_to_face(&self, solid: &Solid, face: u32, tolerance: Option<f64>) -> Result<NurbsCurve> {
        let mut error = 0.0;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_pulled_to_face)(self.raw(), solid.raw(), face, tol_arg(tolerance), &mut error) };
        NurbsCurve::fitted(self.api, raw, error, "nurbs_curve_pulled_to_face")
    }

    /// The same curve run the other way over the same domain.
    pub fn reversed(&self) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_reversed)(self.raw()) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_reversed")
    }

    /// The part from `t0` to `t1` (`t0 < t1`, inside the domain), over `t0..t1`.
    pub fn trimmed(&self, t0: f64, t1: f64) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_trimmed)(self.raw(), t0, t1) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_trimmed")
    }

    /// This curve continued `length` past its end (or its start when `at_start`) along its own
    /// end polynomial -- position, tangent and curvature there unchanged, every old parameter
    /// its old point.
    pub fn extended(&self, length: f64, at_start: bool) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_extended)(self.raw(), at_start, length) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_extended")
    }

    /// The same curve at degree `degree + by` (at most 12).
    pub fn elevated(&self, by: u32) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_elevated)(self.raw(), by) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_elevated")
    }

    /// This curve through the affine map `t`: its control points mapped, weights and knots kept
    /// -- exact. A singular map (a projection) is allowed.
    pub fn transformed(&self, t: &Transform) -> Result<NurbsCurve> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_transformed)(self.raw(), t.rows.as_ptr()) };
        NurbsCurve::wrap(self.api, raw, "nurbs_curve_transformed")
    }

    // ---- reading ----------------------------------------------------------------------

    /// The largest distance from a fitted-to point or surface to this curve: set only on curves
    /// from [`fit`](Self::fit), [`projected_to_face`](Self::projected_to_face) and
    /// [`pulled_to_face`](Self::pulled_to_face).
    pub fn fit_error(&self) -> Option<f64> {
        self.fit_error
    }

    pub fn degree(&self) -> u32 {
        unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_degree)(self.raw()) }
    }

    pub fn control_points(&self) -> Result<Vec<[f64; 3]>> {
        let n = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_control_count)(self.raw()) } as usize;
        let mut out = vec![0.0; 3 * n];
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_control_points)(self.raw(), out.as_mut_ptr()) } {
            return Err(fail(self.api, "nurbs_curve_control_points"));
        }
        Ok(out.chunks_exact(3).map(|p| [p[0], p[1], p[2]]).collect())
    }

    /// One weight per control point (all 1 for a non-rational curve).
    pub fn weights(&self) -> Result<Vec<f64>> {
        let n = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_control_count)(self.raw()) } as usize;
        let mut out = vec![0.0; n];
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_weights)(self.raw(), out.as_mut_ptr()) } {
            return Err(fail(self.api, "nurbs_curve_weights"));
        }
        Ok(out)
    }

    pub fn knots(&self) -> Result<Vec<f64>> {
        let n = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_knot_count)(self.raw()) } as usize;
        let mut out = vec![0.0; n];
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_knots)(self.raw(), out.as_mut_ptr()) } {
            return Err(fail(self.api, "nurbs_curve_knots"));
        }
        Ok(out)
    }

    pub fn domain(&self) -> Result<(f64, f64)> {
        let d = written::<2>("nurbs_curve_domain", |api, out| unsafe { (api.cadaclysm_blacksmith_nurbs_curve_domain)(self.raw(), out) })?;
        Ok((d[0], d[1]))
    }

    pub fn is_rational(&self) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_is_rational)(self.raw()) }
    }

    /// Whether the curve closes on itself (the answer, not a flag).
    pub fn is_closed(&self) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_is_closed)(self.raw()) }
    }

    /// The point at parameter `t`, inside the domain.
    pub fn point(&self, t: f64) -> Result<[f64; 3]> {
        written::<3>("nurbs_curve_point", |api, out| unsafe { (api.cadaclysm_blacksmith_nurbs_curve_point)(self.raw(), t, out) })
    }

    /// The point and its derivatives at `t` up to `order` (at most 8): `[C, C', C'', ...]`, so
    /// `order + 1` vectors.
    pub fn derivatives(&self, t: f64, order: u32) -> Result<Vec<[f64; 3]>> {
        let mut out = vec![0.0; 3 * (order.min(8) as usize + 1)];
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_derivatives)(self.raw(), t, order, out.as_mut_ptr()) } {
            return Err(fail(self.api, "nurbs_curve_derivatives"));
        }
        Ok(out.chunks_exact(3).map(|p| [p[0], p[1], p[2]]).collect())
    }

    /// The curvature and Frenet frame at `t`.
    pub fn curvature(&self, t: f64) -> Result<Curvature> {
        let mut raw = sys::CadaclysmBlacksmithCurvature::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_curvature)(self.raw(), t, &mut raw) } {
            return Err(fail(self.api, "nurbs_curve_curvature"));
        }
        Ok(raw.into())
    }

    /// The curve's length, to the relative `accuracy` (0 asks for the default).
    pub fn length(&self, accuracy: f64) -> Result<Length> {
        let mut raw = sys::CadaclysmBlacksmithLength::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_length)(self.raw(), accuracy, &mut raw) } {
            return Err(fail(self.api, "nurbs_curve_length"));
        }
        Ok(raw.into())
    }

    /// The point at arc length `s` from the curve's start.
    pub fn point_at_length(&self, s: f64, accuracy: f64) -> Result<At> {
        let mut raw = sys::CadaclysmBlacksmithAt::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_point_at_length)(self.raw(), s, accuracy, &mut raw) } {
            return Err(fail(self.api, "nurbs_curve_point_at_length"));
        }
        Ok(raw.into())
    }

    /// The curve in `n` pieces of equal arc length: `n + 1` samples, `n` for a closed curve.
    pub fn divide_by_count(&self, n: u32, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_divide_by_count)(self.raw(), n, accuracy) };
        samples_of(self.api, raw, "nurbs_curve_divide_by_count")
    }

    /// Samples every `step` of arc length from the start; a closed curve never repeats it.
    pub fn divide_by_length(&self, step: f64, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_divide_by_length)(self.raw(), step, accuracy) };
        samples_of(self.api, raw, "nurbs_curve_divide_by_length")
    }

    /// Where the curve crosses the plane through `origin` with `normal`, in parameter order
    /// (`error` each point's distance from the plane). Refused for a curve lying in the plane; a
    /// touch that does not cross is not listed.
    pub fn plane_hits(&self, origin: [f64; 3], normal: [f64; 3]) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_plane_hits)(self.raw(), origin.as_ptr(), normal.as_ptr()) };
        samples_of(self.api, raw, "nurbs_curve_plane_hits")
    }

    /// Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance` of
    /// it, in parameter order (`error` each point's distance from the surface).
    pub fn face_hits(&self, solid: &Solid, face: u32, tolerance: Option<f64>) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_nurbs_curve_face_hits)(self.raw(), solid.raw(), face, tol_arg(tolerance)) };
        samples_of(self.api, raw, "nurbs_curve_face_hits")
    }

    /// A curvature comb to draw: at `n + 1` even parameters (`max(n, 1)` steps), the curve point
    /// and that point moved by `-scale * kappa * normal` (out of the bend). Straight stretches
    /// give zero teeth.
    pub fn comb(&self, n: u32, scale: f64) -> Result<Vec<([f64; 3], [f64; 3])>> {
        let (lo, hi) = self.domain()?;
        let steps = n.max(1);
        let mut out = Vec::with_capacity(steps as usize + 1);
        for i in 0..=steps {
            let t = lo + (hi - lo) * f64::from(i) / f64::from(steps);
            let k = self.curvature(t)?;
            let p = self.point(t)?;
            out.push((p, [p[0] - scale * k.kappa * k.normal[0], p[1] - scale * k.kappa * k.normal[1], p[2] - scale * k.kappa * k.normal[2]]));
        }
        Ok(out)
    }
}

// ---- Sheets from curves: lofts, sweeps, Coons and Gordon sheets, matching, trimming, joining ----

/// The tolerance the fitted sheets ([`Solid::sweep_rail`], [`Solid::sweep_two_rails`],
/// [`Solid::edge_surface`], [`Solid::network_surface`], [`Solid::fillet_surfaces`]) are usually
/// given; `None` asks for the inputs' effective tolerance.
pub const SHEET_TOLERANCE: f64 = 1e-3;

/// A side of a NURBS face: a boundary isocurve of its surface (`"u0"`, `"u1"`, `"v0"`, `"v1"`
/// parse to the four).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SheetSide {
    /// The `u = 0` isocurve.
    U0,
    /// The `u = 1` isocurve.
    U1,
    /// The `v = 0` isocurve.
    V0,
    /// The `v = 1` isocurve.
    V1,
}

impl SheetSide {
    fn code(self) -> u32 {
        match self {
            SheetSide::U0 => 0,
            SheetSide::U1 => 1,
            SheetSide::V0 => 2,
            SheetSide::V1 => 3,
        }
    }
}

impl std::str::FromStr for SheetSide {
    type Err = Error;

    fn from_str(s: &str) -> Result<SheetSide> {
        match s {
            "u0" => Ok(SheetSide::U0),
            "u1" => Ok(SheetSide::U1),
            "v0" => Ok(SheetSide::V0),
            "v1" => Ok(SheetSide::V1),
            other => Err(Error::new(format!("a side is 'u0', 'u1', 'v0' or 'v1', not '{other}'"))),
        }
    }
}

/// The frame [`Solid::sweep_rail`] carries its sections by (`"rmf"` and `"fixed"` parse to them).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SweepFrame {
    /// Rotation-minimising.
    Rmf,
    /// Keeping the given `up` upright.
    Fixed,
}

impl SweepFrame {
    fn code(self) -> u32 {
        match self {
            SweepFrame::Rmf => 0,
            SweepFrame::Fixed => 1,
        }
    }
}

impl std::str::FromStr for SweepFrame {
    type Err = Error;

    fn from_str(s: &str) -> Result<SweepFrame> {
        match s {
            "rmf" => Ok(SweepFrame::Rmf),
            "fixed" => Ok(SweepFrame::Fixed),
            other => Err(Error::new(format!("sweep_rail: frame is 'rmf' or 'fixed', not '{other}'"))),
        }
    }
}

/// Which side [`Solid::trim_by_curve`] keeps (`"outside"`, `"inside"`, `"left"`, `"right"` parse
/// to them): `Inside` and `Left` are the island a closed curve bounds / the side left of an open
/// curve's run, `Outside` and `Right` the rest.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrimKeep {
    Outside,
    Inside,
    Left,
    Right,
}

impl TrimKeep {
    fn keep_inside(self) -> bool {
        matches!(self, TrimKeep::Inside | TrimKeep::Left)
    }
}

impl std::str::FromStr for TrimKeep {
    type Err = Error;

    fn from_str(s: &str) -> Result<TrimKeep> {
        match s {
            "outside" => Ok(TrimKeep::Outside),
            "inside" => Ok(TrimKeep::Inside),
            "left" => Ok(TrimKeep::Left),
            "right" => Ok(TrimKeep::Right),
            other => Err(Error::new(format!("trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not '{other}'"))),
        }
    }
}

/// How well two faces meet along their sides ([`Solid::continuity`]): the largest `gap` between
/// the sides (G0), the largest `angle` between their normals in radians (G1), the largest
/// difference of normal `curvature` across the edge (G2), each with where it was found
/// (`gap_at`, `angle_at`, `curvature_at`), and how many points were asked (`samples`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Continuity {
    pub gap: f64,
    pub gap_at: [f64; 3],
    pub angle: f64,
    pub angle_at: [f64; 3],
    pub curvature: f64,
    pub curvature_at: [f64; 3],
    pub samples: u32,
}

impl From<sys::CadaclysmBlacksmithContinuity> for Continuity {
    fn from(r: sys::CadaclysmBlacksmithContinuity) -> Continuity {
        Continuity {
            gap: r.gap,
            gap_at: r.gap_at,
            angle: r.angle,
            angle_at: r.angle_at,
            curvature: r.curvature,
            curvature_at: r.curvature_at,
            samples: r.samples,
        }
    }
}

/// How well an N-sided patch ([`Solid::n_sided_patch`]) meets: `faces` sub-patches, the worst
/// `boundary` against the neighbours (the gap over every side, the angle over those met at G1
/// or G2, the curvature jump over those at G2), the worst `internal` across the patch's own
/// spokes, and `corner_angle` (radians), the most a corner of the hole leaves no patch able to
/// meet: zero where the neighbours meet each other at G1.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PatchReport {
    pub faces: u32,
    pub boundary: Continuity,
    pub internal: Continuity,
    pub corner_angle: f64,
}

impl From<sys::CadaclysmBlacksmithPatchReport> for PatchReport {
    fn from(r: sys::CadaclysmBlacksmithPatchReport) -> PatchReport {
        PatchReport { faces: r.faces, boundary: r.boundary.into(), internal: r.internal.into(), corner_angle: r.corner_angle }
    }
}

/// What [`Solid::join_sheets`] did: `sewn` edges (each two naked edges become one shared edge),
/// the widest `worst_gap` between two sewn edges (0 where all met exactly), the naked edges --
/// bordered by one face -- `naked_before` (once the T-junctions are cut) and `naked_after`,
/// `refused` groups of naked edges that share both ends but were left apart, faces `turned`, and
/// whether the result is `closed`: a solid.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct JoinReport {
    pub sewn: u32,
    pub worst_gap: f64,
    pub naked_before: u32,
    pub naked_after: u32,
    pub refused: u32,
    pub turned: u32,
    pub closed: bool,
}

impl From<sys::CadaclysmBlacksmithJoinReport> for JoinReport {
    fn from(r: sys::CadaclysmBlacksmithJoinReport) -> JoinReport {
        JoinReport {
            sewn: r.sewn,
            worst_gap: r.worst_gap,
            naked_before: r.naked_before,
            naked_after: r.naked_after,
            refused: r.refused,
            turned: r.turned,
            closed: r.closed != 0,
        }
    }
}

/// One boundary of the hole [`Solid::n_sided_patch`] fills: a side of a sheet's face met at
/// G`level` (0, 1 or 2; [`PatchBoundary::side`] gives 2), over `range` of the side's parameter
/// (`(0, 1)` the whole side, `(1, 0)` backwards), or a [`NurbsCurve`] met at G0.
#[derive(Clone, Copy, Debug)]
pub enum PatchBoundary<'a> {
    Side { sheet: &'a Solid, face: u32, side: SheetSide, range: (f64, f64), level: u32 },
    Curve(&'a NurbsCurve),
}

impl<'a> PatchBoundary<'a> {
    /// Face 0 of `sheet`, its side `side`, the whole side, met at G2.
    pub fn side(sheet: &'a Solid, side: SheetSide) -> PatchBoundary<'a> {
        PatchBoundary::Side { sheet, face: 0, side, range: (0.0, 1.0), level: 2 }
    }

    /// `curve`, met at G0.
    pub fn curve(curve: &'a NurbsCurve) -> PatchBoundary<'a> {
        PatchBoundary::Curve(curve)
    }

    /// Met at G`level` (a curve boundary is always G0: unchanged).
    pub fn level(mut self, to: u32) -> PatchBoundary<'a> {
        if let PatchBoundary::Side { level, .. } = &mut self {
            *level = to;
        }
        self
    }

    /// On face `to` of the sheet (unchanged for a curve).
    pub fn face(mut self, to: u32) -> PatchBoundary<'a> {
        if let PatchBoundary::Side { face, .. } = &mut self {
            *face = to;
        }
        self
    }

    /// Over `from..to` of the side's parameter (unchanged for a curve).
    pub fn range(mut self, from: f64, to: f64) -> PatchBoundary<'a> {
        if let PatchBoundary::Side { range, .. } = &mut self {
            *range = (from, to);
        }
        self
    }

    fn raw(&self) -> sys::CadaclysmBlacksmithPatchBoundary {
        match *self {
            PatchBoundary::Side { sheet, face, side, range, level } => sys::CadaclysmBlacksmithPatchBoundary {
                sheet: sheet.handle.as_ptr(),
                face,
                side: side.code(),
                from: range.0,
                to: range.1,
                level,
                curve: ptr::null(),
            },
            PatchBoundary::Curve(curve) => sys::CadaclysmBlacksmithPatchBoundary {
                sheet: ptr::null(),
                face: 0,
                side: 0,
                from: 0.0,
                to: 1.0,
                level: 0,
                curve: curve.raw(),
            },
        }
    }
}

impl<'a> From<&'a NurbsCurve> for PatchBoundary<'a> {
    fn from(curve: &'a NurbsCurve) -> PatchBoundary<'a> {
        PatchBoundary::Curve(curve)
    }
}

/// The handles of a curve list, for the C calls (the curves stay borrowed for the call).
fn curve_handles(curves: &[&NurbsCurve]) -> Vec<*const sys::CadaclysmBlacksmithNurbsCurve> {
    curves.iter().map(|c| c.raw()).collect()
}

impl Solid {
    /// This sheet with the fit error the library wrote.
    fn fitted(raw: Result<Solid>, error: f64) -> Result<Solid> {
        let mut sheet = raw?;
        sheet.sheet_error = Some(error);
        Ok(sheet)
    }

    /// On a sheet from [`sweep_rail`](Self::sweep_rail), [`sweep_two_rails`](Self::sweep_two_rails),
    /// [`edge_surface`](Self::edge_surface), [`network_surface`](Self::network_surface),
    /// [`fillet_surfaces`](Self::fillet_surfaces), [`flange`](Self::flange) or
    /// [`extrude_to`](Self::extrude_to), how close the fitted sheet is to what it was
    /// asked to be (the largest distance to the curves given, or the fit error); `None` on every
    /// other solid.
    pub fn sheet_error(&self) -> Option<f64> {
        self.sheet_error
    }

    /// On the sheet [`n_sided_patch`](Self::n_sided_patch) made, how well it meets its
    /// neighbours; `None` on every other solid.
    pub fn patch_report(&self) -> Option<&PatchReport> {
        self.patch_report.as_ref()
    }

    /// The sheet lofted through `sections`, `degree` across them (lowered to fit); `loose`
    /// shapes it by them instead, through the first and last only; `closed` makes it periodic
    /// across them, the last section back to the first. One face on one NURBS surface.
    pub fn loft_curves(sections: &[&NurbsCurve], degree: u32, loose: bool, closed: bool) -> Result<Solid> {
        let api = api()?;
        let handles = curve_handles(sections);
        let raw = unsafe { (api.cadaclysm_blacksmith_loft_curves)(handles.as_ptr(), handles.len(), degree, loose, closed) };
        Solid::wrap(api, raw, "loft_curves")
    }

    /// `sections` swept along `rail`, each carried by the rail's frame from the rail point
    /// nearest its centre and blended between: [`SweepFrame::Rmf`] rotation-minimising,
    /// [`SweepFrame::Fixed`] keeping `up` upright. Fitted within `tolerance`
    /// ([`SHEET_TOLERANCE`] usually); the sheet's [`sheet_error`](Self::sheet_error) says how close.
    pub fn sweep_rail(rail: &NurbsCurve, sections: &[&NurbsCurve], frame: SweepFrame, up: Option<[f64; 3]>, tolerance: Option<f64>) -> Result<Solid> {
        let api = api()?;
        let handles = curve_handles(sections);
        let mut error = 0.0;
        let raw = unsafe {
            (api.cadaclysm_blacksmith_sweep_rail)(rail.raw(), handles.as_ptr(), handles.len(), frame.code(), opt_ptr(&up), tol_arg(tolerance), &mut error)
        };
        Solid::fitted(Solid::wrap(api, raw, "sweep_rail"), error)
    }

    /// `sections` swept between two rails: each section's first end on `rail_a` and last on
    /// `rail_b`, carried by the rotation and uniform scale that keep them there, the rails
    /// matched by arc length. Fitted within `tolerance` ([`sheet_error`](Self::sheet_error)).
    pub fn sweep_two_rails(rail_a: &NurbsCurve, rail_b: &NurbsCurve, sections: &[&NurbsCurve], tolerance: Option<f64>) -> Result<Solid> {
        let api = api()?;
        let handles = curve_handles(sections);
        let mut error = 0.0;
        let raw = unsafe {
            (api.cadaclysm_blacksmith_sweep_two_rails)(rail_a.raw(), rail_b.raw(), handles.as_ptr(), handles.len(), tol_arg(tolerance), &mut error)
        };
        Solid::fitted(Solid::wrap(api, raw, "sweep_two_rails"), error)
    }

    /// The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance` (in
    /// order round the boundary, each either way round): exact for non-rational boundaries,
    /// rational ones fitted first ([`sheet_error`](Self::sheet_error)).
    pub fn edge_surface(curves: &[&NurbsCurve], tolerance: Option<f64>) -> Result<Solid> {
        let api = api()?;
        let handles = curve_handles(curves);
        let mut error = 0.0;
        let raw = unsafe { (api.cadaclysm_blacksmith_edge_surface)(handles.as_ptr(), handles.len(), tol_arg(tolerance), &mut error) };
        Solid::fitted(Solid::wrap(api, raw, "edge_surface"), error)
    }

    /// The Gordon sheet of a curve network: `u_curves` (in order across the other way) and
    /// `v_curves`, every one of the first crossing every one of the second within `tolerance`.
    /// [`sheet_error`](Self::sheet_error) is the largest distance from the sheet to the curves.
    pub fn network_surface(u_curves: &[&NurbsCurve], v_curves: &[&NurbsCurve], tolerance: Option<f64>) -> Result<Solid> {
        let api = api()?;
        let (u, v) = (curve_handles(u_curves), curve_handles(v_curves));
        let mut error = 0.0;
        let raw = unsafe {
            (api.cadaclysm_blacksmith_network_surface)(u.as_ptr(), u.len(), v.as_ptr(), v.len(), tol_arg(tolerance), &mut error)
        };
        Solid::fitted(Solid::wrap(api, raw, "network_surface"), error)
    }

    /// How well face `face` of this solid, along `side`, meets face `other_face` of `other`
    /// along `other_side`, from `samples` points along the first side (64 usually): the largest
    /// gap, angle between the normals and difference of curvature, with where each is.
    pub fn continuity(&self, side: SheetSide, other: &Solid, other_side: SheetSide, face: u32, other_face: u32, samples: u32) -> Result<Continuity> {
        let mut out = sys::CadaclysmBlacksmithContinuity::default();
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_continuity)(self.raw(), face, side.code(), other.raw(), other_face, other_side.code(), samples, &mut out)
        };
        if ok {
            Ok(out.into())
        } else {
            Err(fail(self.api, "continuity"))
        }
    }

    /// Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `other_side` at
    /// G`level` (2 usually): 0 position, 1 tangent plane, 2 curvature. The opposite side stays
    /// where it was.
    pub fn matched(&self, side: SheetSide, other: &Solid, other_side: SheetSide, level: u32, face: u32, other_face: u32) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_match_side)(self.raw(), face, side.code(), other.raw(), other_face, other_side.code(), level)
        };
        self.next(raw, "match_side")
    }

    /// A sheet spanning from `a`'s side to `b`'s, meeting each at G`level` (1 or 2); `bulge`
    /// (1 usually) scales how far it leaves each edge along its neighbour's tangent.
    #[allow(clippy::too_many_arguments)]
    pub fn blend_sides(a: &Solid, side_a: SheetSide, b: &Solid, side_b: SheetSide, level: u32, bulge: f64, face_a: u32, face_b: u32) -> Result<Solid> {
        let raw = unsafe {
            (a.api.cadaclysm_blacksmith_blend_sides)(a.raw(), face_a, side_a.code(), b.raw(), face_b, side_b.code(), level, bulge)
        };
        a.next(raw, "blend_sides")
    }

    /// The sheet filling a hole of 3 or more sides: N four-sided NURBS faces round a central
    /// point, G1 or G2 to each other. Each boundary, in order round the hole and either way
    /// round, is a [`PatchBoundary`]: a sheet's side, or a [`NurbsCurve`] met at G0. They must
    /// meet end to end within `tolerance` (0.01 usually); `bulge` (1 usually) scales how far the
    /// patch leaves each neighbour along its tangent. Face `i` meets boundary `i`'s second half
    /// along its `V0` side and boundary `i + 1`'s first half along its `U1`, so
    /// [`continuity`](Self::continuity) measures each neighbour; the result's
    /// [`patch_report`](Self::patch_report) holds the worst of them, measured the same way.
    pub fn n_sided_patch(boundaries: &[PatchBoundary<'_>], bulge: f64, tolerance: Option<f64>) -> Result<Solid> {
        let api = api()?;
        let rows: Vec<sys::CadaclysmBlacksmithPatchBoundary> = boundaries.iter().map(PatchBoundary::raw).collect();
        let mut report = sys::CadaclysmBlacksmithPatchReport::default();
        let raw = unsafe { (api.cadaclysm_blacksmith_n_sided_patch)(rows.as_ptr(), rows.len(), bulge, tol_arg(tolerance), &mut report) };
        let mut patch = Solid::wrap(api, raw, "n_sided_patch")?;
        patch.patch_report = Some(report.into());
        Ok(patch)
    }

    /// The rolling-ball fillet between face `face_a` of `a` and face `face_b` of `b` (their
    /// whole NURBS surfaces): the ball on the side each face's normal points to (`flip_a` /
    /// `flip_b`: the other side), of `radius`, or running linearly from `radius` to `radius_end`
    /// along the fillet. Returns the fillet sheet (its [`sheet_error`](Self::sheet_error) set)
    /// and the contact curves on `a` and `b`, to trim them back with
    /// [`trim_by_curve`](Self::trim_by_curve) and join with [`join_sheets`](Self::join_sheets).
    /// The curves are the caller's, and outlive the sheets.
    #[allow(clippy::too_many_arguments)]
    pub fn fillet_surfaces(
        a: &Solid,
        b: &Solid,
        radius: f64,
        radius_end: Option<f64>,
        flip_a: bool,
        flip_b: bool,
        tolerance: Option<f64>,
        face_a: u32,
        face_b: u32,
    ) -> Result<(Solid, NurbsCurve, NurbsCurve)> {
        let api = a.api;
        let mut rail_a: *mut sys::CadaclysmBlacksmithNurbsCurve = ptr::null_mut();
        let mut rail_b: *mut sys::CadaclysmBlacksmithNurbsCurve = ptr::null_mut();
        let mut error = 0.0;
        let raw = unsafe {
            (api.cadaclysm_blacksmith_fillet_surfaces)(
                a.raw(),
                face_a,
                b.raw(),
                face_b,
                radius,
                radius_end.unwrap_or(radius),
                flip_a,
                flip_b,
                tol_arg(tolerance),
                &mut rail_a,
                &mut rail_b,
                &mut error,
            )
        };
        // Own whatever rails came back first, so every path frees them.
        let own = |raw: *mut sys::CadaclysmBlacksmithNurbsCurve| NonNull::new(raw).map(|handle| NurbsCurve { handle, api, fit_error: None });
        let (rail_a, rail_b) = (own(rail_a), own(rail_b));
        let sheet = Solid::fitted(Solid::wrap(api, raw, "fillet_surfaces"), error)?;
        match (rail_a, rail_b) {
            (Some(ra), Some(rb)) => Ok((sheet, ra, rb)),
            _ => Err(Error::new("fillet_surfaces: the library returned no contact curves")),
        }
    }

    /// [`fillet`](Self::fillet) with the radius running linearly from `radius` to `radius_end`
    /// in arc length along each edge, `radius` at the end where the edge's curve starts (spline
    /// edges only: the crease between two faces on NURBS surfaces). A `radius_end` of `None` or
    /// equal to `radius` is the constant [`fillet`](Self::fillet).
    pub fn fillet_varying(&self, edges: &[u32], radius: f64, radius_end: Option<f64>, tolerance: f64) -> Result<Solid> {
        match radius_end {
            Some(end) if end != radius => {
                let raw = unsafe { (self.api.cadaclysm_blacksmith_fillet_varying)(self.raw(), edges.as_ptr(), edges.len(), radius, end, tolerance) };
                self.next(raw, "fillet_varying")
            }
            _ => self.fillet(edges, radius, tolerance),
        }
    }

    /// This sheet cut along `curve` -- one lying on it, say projected or pulled onto it -- and
    /// nothing removed: every face comes back in its pieces outside the cutter, then its pieces
    /// inside, each a face. The cutter is `curve` run along `direction` (`None`: the mean of the
    /// sheet's normals along the curve) through the whole sheet. A closed curve's inside is the
    /// island it bounds; an open curve's is the side left of its run, seen from where
    /// `direction` points, and an open curve is run on straight past both ends, so it should
    /// cross the sheet's boundary. `tolerance` (0.05 usually) is the split's meshing tolerance.
    pub fn split_by_curve(&self, curve: &NurbsCurve, direction: Option<[f64; 3]>, tolerance: Option<f64>) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_split_by_curve)(self.raw(), curve.raw(), opt_ptr(&direction), tol_arg(tolerance)) };
        self.next(raw, "split_by_curve")
    }

    /// This sheet cut along `curve` and one side thrown away (see
    /// [`split_by_curve`](Self::split_by_curve)): [`TrimKeep::Inside`] keeps the island a closed
    /// curve bounds, [`TrimKeep::Outside`] the sheet with the hole; for an open curve
    /// [`TrimKeep::Left`] (the same as `Inside`) keeps the side left of its run seen from where
    /// `direction` points, [`TrimKeep::Right`] the other. Refused where nothing of the sheet lies
    /// on the kept side.
    pub fn trim_by_curve(&self, curve: &NurbsCurve, keep: TrimKeep, direction: Option<[f64; 3]>, tolerance: Option<f64>) -> Result<Solid> {
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_trim_by_curve)(self.raw(), curve.raw(), opt_ptr(&direction), keep.keep_inside(), tol_arg(tolerance))
        };
        self.next(raw, "trim_by_curve")
    }

    /// `section` swept along each of `edges` (naked edges of this sheet, indices into
    /// [`edges`](Self::edges)) on the face's own frame: at every point of the edge the section's
    /// `x` runs outward from the face -- square to the edge, in the face's tangent plane -- and
    /// its `y` along the face's normal, so a section from `(0, 0)` to `(0, -10)` turns the edge
    /// under by 10 all along it however the panel curves, `(0, 0)` to `(10, 0)` carries the face
    /// on, and a lip stands proud with `y > 0`. `section` is a curve in the plane `z = 0`
    /// starting at the origin. With `join` the sweeps come back sewn to this sheet (its faces
    /// first, then one per edge), else alone, sewn to each other. Each sweep is fitted within
    /// `tolerance` (1e-3 usually); the result's [`sheet_error`](Self::sheet_error) says how
    /// close. Refused for an edge bordered by two faces, a section not starting at the origin,
    /// and sweeps that did not sew on.
    pub fn flange(&self, edges: &[u32], section: &NurbsCurve, tolerance: Option<f64>, join: bool) -> Result<Solid> {
        let mut error = 0.0;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_flange)(self.raw(), edges.as_ptr(), edges.len(), section.raw(), tol_arg(tolerance), join, &mut error)
        };
        Solid::fitted(self.next(raw, "flange"), error)
    }

    /// Each of `edges` (naked edges of this sheet, indices into [`edges`](Self::edges)) slid
    /// along `direction` until it meets `target`: every point of the edge travels along the
    /// direction to its first hit on `target`'s faces (trimmed, not their whole surfaces). One
    /// wall per edge -- the edge's own curve swept straight, bounded by the curve through the
    /// hits, fitted within `tolerance` (1e-3 usually) of every hit
    /// ([`sheet_error`](Self::sheet_error)) -- so a wheel arch cut in a panel runs in to the
    /// well's inner wall as its liner. With `join` the walls come back sewn to this sheet (its
    /// faces first, then one per edge), else alone, sewn to each other. Refused as
    /// [`flange`](Self::flange) is, for a direction of no length, and naming the point whose
    /// line misses the target.
    pub fn extrude_to(&self, edges: &[u32], direction: [f64; 3], target: &Solid, tolerance: Option<f64>, join: bool) -> Result<Solid> {
        let mut error = 0.0;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_extrude_to)(
                self.raw(),
                edges.as_ptr(),
                edges.len(),
                direction.as_ptr(),
                target.raw(),
                tol_arg(tolerance),
                join,
                &mut error,
            )
        };
        Solid::fitted(self.next(raw, "extrude_to"), error)
    }

    /// `sheets` joined into one body, their faces in order, and a [`JoinReport`] of what was
    /// done: every two naked edges whose ends and curves agree within `tolerance` (`None` or 0:
    /// a rounding of the body's size) sewn into one -- a gap closed is kept as that edge's own
    /// tolerance -- the faces turned to agree, and a closed result turned to face out, a solid
    /// the booleans, the measures and the writers take. At a tolerance above 0 a T-junction is
    /// sewn too: one sheet's edge along part of another's is first cut where the other's
    /// corner lies on it.
    pub fn join_sheets(sheets: &[&Solid], tolerance: Option<f64>) -> Result<(Solid, JoinReport)> {
        let api = api()?;
        let handles: Vec<*const sys::CadaclysmBlacksmithSolid> = sheets.iter().map(|s| s.raw()).collect();
        let mut report = sys::CadaclysmBlacksmithJoinReport::default();
        let raw = unsafe { (api.cadaclysm_blacksmith_join_sheets)(handles.as_ptr(), handles.len(), tol_arg(tolerance), &mut report) };
        Ok((Solid::wrap(api, raw, "join_sheets")?, report.into()))
    }

    /// This sheet with an opening recessed into it along `outline` -- a window, a lamp, a grille
    /// or an air intake set into a panel -- and how many of the result's faces are each part's:
    /// `(sheet, fillet, walls, pane)`, the faces in that order.
    ///
    /// `outline` is a closed curve on the sheet (one face or several joined); each of its points
    /// is found on the sheet, so it may stand a little off it. The walls run back `depth` along
    /// the sheet's own normal at every point of the rim -- not along one view -- behind the face
    /// (against its normal; negative: in front), leaning in toward the opening by `draft` radians
    /// (negative: out) and meeting on the mitre at the outline's corners. `fillet` above 0 rounds
    /// the rim between the sheet and the walls (the outline must then be smooth). `pane` closes
    /// the back with one patch whose four sides end where the outline turns most, so it does not
    /// twist. Every piece is sewn to the next: only the sheet's own boundary is left naked, and
    /// the walls' foot without a pane. Refused for an outline that is not closed, a corner with a
    /// fillet, or a fillet deeper than the walls. Python's defaults: draft 0, fillet 0, pane
    /// true, tolerance 0.05.
    #[allow(clippy::too_many_arguments)]
    pub fn recess(&self, outline: &NurbsCurve, depth: f64, draft: f64, fillet: f64, pane: bool, tolerance: Option<f64>) -> Result<(Solid, (u32, u32, u32, u32))> {
        let mut faces = [0u32; 4];
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_recess)(self.raw(), outline.raw(), depth, draft, fillet, pane, tol_arg(tolerance), faces.as_mut_ptr())
        };
        Ok((self.next(raw, "recess")?, (faces[0], faces[1], faces[2], faces[3])))
    }
}

/// The exact NURBS form of a curve value of `kind`.
fn curve_to_nurbs(kind: u32, v: &[f64]) -> Result<NurbsCurve> {
    let api = api()?;
    NurbsCurve::wrap(api, unsafe { (api.cadaclysm_blacksmith_curve_value_to_nurbs)(kind, v.as_ptr()) }, "curve_value_to_nurbs")
}

/// The closest points between two solids' boundaries ([`Solid::closest`]). `kind_*` is
/// `"face"`, `"edge"` or `"vertex"`; `index_*` the kernel id of it; `edge_*` the index
/// [`Solid::fillet`] takes, `None` for a face, a vertex or an edge with no exact curve.
/// `refined`: the points were refined onto the exact geometry, not the mesh's answer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Closest {
    pub distance: f64,
    pub on_a: [f64; 3],
    pub on_b: [f64; 3],
    pub kind_a: String,
    pub index_a: u32,
    pub edge_a: Option<u32>,
    pub kind_b: String,
    pub index_b: u32,
    pub edge_b: Option<u32>,
    pub refined: bool,
}

/// `"outside"`, `"inside"` or `"on"` from the library's 0, 1 or 2.
fn containment(what: &str, code: u32) -> Result<&'static str> {
    match code {
        0 => Ok("outside"),
        1 => Ok("inside"),
        2 => Ok("on"),
        n => Err(Error::new(format!("{what}: the library answered {n}, not a containment code"))),
    }
}

/// One closed solid's reusable point classifier ([`Solid::classifier`]). It keeps its own
/// reference to the body, so it goes on answering after its [`Solid`] is dropped. Dropping it
/// frees the handle.
pub struct Classifier {
    handle: NonNull<sys::CadaclysmBlacksmithClassifier>,
    api: &'static Api,
}

// SAFETY: the library wraps its classifier in a mutex (calls from several threads serialise),
// and the handle holds its own reference to the body, so it may move and be shared.
unsafe impl Send for Classifier {}
unsafe impl Sync for Classifier {}

impl Drop for Classifier {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_classifier_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Classifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Classifier({:p})", self.handle)
    }
}

impl Classifier {
    /// `"outside"`, `"inside"` or `"on"` (within the classifier's tolerance) for `point`.
    pub fn contains(&self, point: [f64; 3]) -> Result<&'static str> {
        let mut code = 0u32;
        if !unsafe { (self.api.cadaclysm_blacksmith_classifier_contains)(self.handle.as_ptr(), point.as_ptr(), &mut code) } {
            return Err(fail(self.api, "classifier_contains"));
        }
        containment("classifier_contains", code)
    }
}

impl Profile {
    /// The perimeter of the outer loop (holes are not counted) to a relative `accuracy` in
    /// (0, 1); 0 or less asks for the default.
    pub fn length(&self, accuracy: f64) -> Result<Length> {
        let mut raw = sys::CadaclysmBlacksmithLength::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_profile_length)(self.raw(), accuracy, &mut raw) } {
            return Err(fail(self.api, "profile_length"));
        }
        Ok(raw.into())
    }

    /// The point `s` along the outer loop from its start, to a relative `accuracy` in
    /// (0, 1); 0 or less asks for the default. `segment` is the side it lies on.
    pub fn point_at_length(&self, s: f64, accuracy: f64) -> Result<At> {
        let mut raw = sys::CadaclysmBlacksmithAt::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_profile_point_at_length)(self.raw(), s, accuracy, &mut raw) } {
            return Err(fail(self.api, "profile_point_at_length"));
        }
        Ok(raw.into())
    }

    /// `n` (1 to 1,000,000) samples of the outer loop equally far apart along it: `n`, a
    /// profile's outer loop being closed.
    pub fn divide_by_count(&self, n: u32, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_divide_by_count)(self.raw(), n, accuracy) };
        samples_of(self.api, raw, "profile_divide_by_count")
    }

    /// Samples of the outer loop every `step` along it from its start; the last piece is kept
    /// short, and a closed loop's start is not repeated.
    pub fn divide_by_length(&self, step: f64, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_profile_divide_by_length)(self.raw(), step, accuracy) };
        samples_of(self.api, raw, "profile_divide_by_length")
    }
}

/// An input face (or edge) a tracked solid's face came from: `(operand, id)`, the operand
/// its input's index in the verb's operand order (a boolean's target 0, its tool 1), the id
/// that input face's [`Solid::face_id`] (or [`Solid::edge_id`]).
pub type Origin = (u32, u64);

/// What a verb did to its inputs' faces (or edges) -- what [`Solid::history`] and
/// [`Solid::edge_history`] return, read off the result's ids and origins alone. An input is
/// named by its [`Origin`]. Every list is in `(operand, id)` order, `generated` in id order
/// -- the shape of OpenCascade's `BRepTools_History`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct History {
    /// The inputs that became exactly one output and kept their id, each as
    /// `(input, output id)`.
    pub kept: Vec<(Origin, u64)>,
    /// The inputs split (several outputs name them), merged (their output has other origins
    /// too) or renumbered (a cut's bore, a later operand's clashing id), each as
    /// `(input, output ids)` -- a split's first piece, which keeps the id, first.
    pub modified: Vec<(Origin, Vec<u64>)>,
    /// The outputs with no origin (a fillet's round, the faces a split cuts), in id order.
    pub generated: Vec<u64>,
    /// The inputs no output names (a cut tool's caps).
    pub deleted: Vec<Origin>,
}

/// The four lists of history handle `h`, read whole; `h` freed on every path, a failed
/// read's too. Null `h` is the call's refusal, in `last_error`.
fn read_history(api: &Api, h: *mut sys::CadaclysmBlacksmithHistory, what: &str) -> Result<History> {
    if h.is_null() {
        return Err(fail(api, what));
    }
    let read = || -> Result<History> {
        let (mut operand, mut id, mut out) = (0u32, 0u64, 0u64);
        let mut history = History::default();
        for i in 0..unsafe { (api.cadaclysm_blacksmith_history_kept_count)(h) } {
            if !unsafe { (api.cadaclysm_blacksmith_history_kept_at)(h, i, &mut operand, &mut id, &mut out) } {
                return Err(fail(api, "history_kept_at"));
            }
            history.kept.push(((operand, id), out));
        }
        for i in 0..unsafe { (api.cadaclysm_blacksmith_history_modified_count)(h) } {
            if !unsafe { (api.cadaclysm_blacksmith_history_modified_at)(h, i, &mut operand, &mut id) } {
                return Err(fail(api, "history_modified_at"));
            }
            let n = unsafe { (api.cadaclysm_blacksmith_history_modified_output_count)(h, i) };
            if n == NONE {
                return Err(fail(api, "history_modified_output_count"));
            }
            let outs = (0..n).map(|j| unsafe { (api.cadaclysm_blacksmith_history_modified_output_at)(h, i, j) }).collect();
            history.modified.push(((operand, id), outs));
        }
        let generated = unsafe { (api.cadaclysm_blacksmith_history_generated_count)(h) };
        history.generated = (0..generated).map(|i| unsafe { (api.cadaclysm_blacksmith_history_generated_at)(h, i) }).collect();
        for i in 0..unsafe { (api.cadaclysm_blacksmith_history_deleted_count)(h) } {
            if !unsafe { (api.cadaclysm_blacksmith_history_deleted_at)(h, i, &mut operand, &mut id) } {
                return Err(fail(api, "history_deleted_at"));
            }
            history.deleted.push((operand, id));
        }
        Ok(history)
    };
    let result = read();
    unsafe { (api.cadaclysm_blacksmith_history_free)(h) };
    result
}

/// The attributes C lists by count and `_at`, in key order, copied out of the strings the
/// solid lends.
fn attribute_map(
    api: &Api,
    count: u32,
    key_at: impl Fn(u32) -> *const c_char,
    value_at: impl Fn(u32) -> *const c_char,
) -> Result<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    for i in 0..count {
        let (k, v) = (key_at(i), value_at(i));
        if k.is_null() || v.is_null() {
            return Err(fail(api, "attributes"));
        }
        out.insert(unsafe { text(k) }, unsafe { text(v) });
    }
    Ok(out)
}

/// `pairs` sorted by key, the order `with_attributes` and `with_face_attributes` set them in.
fn by_key<K: AsRef<str>, V: AsRef<str>>(pairs: impl IntoIterator<Item = (K, V)>) -> Vec<(K, V)> {
    let mut pairs: Vec<(K, V)> = pairs.into_iter().collect();
    pairs.sort_by(|a, b| a.0.as_ref().cmp(b.0.as_ref()));
    pairs
}

/// An exact B-rep solid (or open sheet). Immutable: every operation returns a new one.
/// Dropping it frees it. `Send`, not `Sync` -- see the module docs.
pub struct Solid {
    handle: NonNull<sys::CadaclysmBlacksmithSolid>,
    api: &'static Api,
    /// What [`Solid::inexact_trims`] reads: written by `transform` / `convert_to_nurbs`.
    inexact_trims: u32,
    /// What [`Solid::sheet_error`] reads: written by the fitted-sheet verbs.
    sheet_error: Option<f64>,
    /// What [`Solid::patch_report`] reads: written by `n_sided_patch`.
    patch_report: Option<PatchReport>,
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
        NonNull::new(raw).map(|handle| Solid { handle, api, inexact_trims: 0, sheet_error: None, patch_report: None }).ok_or_else(|| fail(api, what))
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

    // -- material and look defined outside the file

    /// This solid made of `material` -- a name, written to STEP as the product's
    /// `MATERIAL_DESIGNATION`. Kept by every operation as the solid's colour is: a move
    /// keeps it, a boolean's result is made of its first solid's. Writing it moves
    /// [`Solid::step`]'s default schema to AP242; a named schema without the entity
    /// drops it, as it drops a colour. Refused when blank.
    pub fn with_material(&self, material: &str) -> Result<Solid> {
        let material = c_text("material", material)?;
        self.next(unsafe { (self.api.cadaclysm_blacksmith_with_material)(self.raw(), material.as_ptr()) }, "with_material")
    }

    /// What this solid is made of, or `None` -- see [`with_material`](Self::with_material).
    pub fn material(&self) -> Option<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_material)(self.raw()) };
        (!raw.is_null()).then(|| unsafe { text(raw) })
    }

    /// This solid drawn in a style defined outside the file: `identification` the
    /// style's name in the library at `location` -- a MaterialX or MDL file and a
    /// material in it, say. Either may be `None`, not both. Written to STEP as an
    /// `EXTERNALLY_DEFINED_STYLE` beside the solid's colour, which a reader without the
    /// library draws instead (AP242 or AP214: the default schema moves to AP242). Kept
    /// by operations as [`with_material`](Self::with_material)'s material is.
    pub fn styled(&self, location: Option<&str>, identification: Option<&str>) -> Result<Solid> {
        let location = location.map(|t| c_text("location", t)).transpose()?;
        let identification = identification.map(|t| c_text("identification", t)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_styled)(
                self.raw(),
                location.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
                identification.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            )
        };
        self.next(raw, "styled")
    }

    /// Where this solid's outside style lives ([`styled`](Self::styled)'s `location`),
    /// or `None`.
    pub fn style_location(&self) -> Option<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_style_location)(self.raw()) };
        (!raw.is_null()).then(|| unsafe { text(raw) })
    }

    /// This solid's outside style's name in its library ([`styled`](Self::styled)'s
    /// `identification`), or `None`.
    pub fn style_identification(&self) -> Option<String> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_style_identification)(self.raw()) };
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

    /// This solid through the affine map `t`, exact, its colours and name kept. A rigid map or
    /// a similarity keeps every surface's kind; a map within 1e-6 of a similarity (`AᵀA` against
    /// `k²I`, relative to `k²` -- a rotation written in float32 among them) is applied as the
    /// exact similarity nearest it, moving a point `p` by at most about `1e-6·|A|·|p|`. Any other
    /// map (a non-uniform scale, a shear) turns the curved surfaces into their exact NURBS and
    /// maps those. The result's [`inexact_trims`](Self::inexact_trims) counts the trims this
    /// call lost. Refused for a singular map (it flattens the solid).
    pub fn transform(&self, t: &Transform) -> Result<Solid> {
        let mut lost = 0u32;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_transform)(self.raw(), t.rows.as_ptr(), &mut lost) };
        let mut out = self.next(raw, "solid_transform")?;
        out.inexact_trims = lost;
        Ok(out)
    }

    /// This solid with the surfaces `level` selects rewritten as their exact NURBS, its colours
    /// and name kept; [`inexact_trims`](Self::inexact_trims) counts the trims this call lost,
    /// as [`transform`](Self::transform)'s does. Refused for a surface or edge curve with no
    /// exact NURBS form.
    pub fn convert_to_nurbs(&self, level: NurbsLevel) -> Result<Solid> {
        let mut lost = 0u32;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_solid_convert_to_nurbs)(self.raw(), level.code(), &mut lost) };
        let mut out = self.next(raw, "solid_convert_to_nurbs")?;
        out.inexact_trims = lost;
        Ok(out)
    }

    /// On a solid from [`transform`](Self::transform) or
    /// [`convert_to_nurbs`](Self::convert_to_nurbs), the trims **that call** lost: face
    /// boundaries kept only as a polyline lifted through the old surface, where no exact edge
    /// curve was left. Per call -- not the solid's history -- and 0 for a rigid map or a
    /// similarity, and on every other solid.
    pub fn inexact_trims(&self) -> u32 {
        self.inexact_trims
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

    /// This solid and `other` as one body that keeps every piece -- a union that keeps the
    /// inside pieces: its regions are this solid less `other`, the two together, and `other`
    /// less this one (those that are not empty), and the walls between them are faces of both.
    /// The body is non-manifold where a wall meets the outside (edges of three or four faces),
    /// so the verbs that need a manifold solid -- the booleans, fillet, chamfer, shell, thicken,
    /// the mass -- refuse it; take its cells with [`Solid::regions`] and [`Solid::region_solid`].
    ///
    /// Built exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus.
    /// Walls of the two lying on one another in part are a case it refuses, in words. A
    /// `tolerance` not positive and finite is refused. Runs silent, as [`Solid::join`] does.
    pub fn merge(&self, other: &Solid, tolerance: f64) -> Result<Solid> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_merge)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut()) };
        self.next(raw, "merge")
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
    /// empty for a partial overlap of curved faces whose outlines cross. Known limit: a crossing narrower
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
        // SAFETY: `found` is a fresh, live intersection, given up here.
        unsafe { intersection_of(self.api, found) }
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

    /// The regions of space this solid's faces bound, region 0 the infinite one: two for an
    /// ordinary solid (outside, inside), one per cell for a [`Solid::merge`]'s body, one more
    /// per cavity. Each lists its [`Region::sides`] -- a face and `sense` +1 where the region is
    /// the side the face's normal points to, -1 the other -- and its `shells`, 1 plus one per
    /// void inside it. Faces that leave an edge the same way are refused.
    pub fn regions(&self) -> Result<Vec<Region>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_regions)(self.raw()) };
        regions_of(self.api, raw)
    }

    /// Finite region `region` (an index into [`Solid::regions`]) as a closed solid of its own:
    /// the faces bounding it, each turned to point out of it, each keeping its colour. Region 0,
    /// the infinite one, and a region past the count are refused.
    pub fn region_solid(&self, region: u32) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_region_solid)(self.raw(), region) }, "region_solid")
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

    /// This solid as the `body` field of a `solid.body` (or `sheet.body`) document node holds
    /// it, as JSON text: the kernel's own B-rep, every table and number as they are, and its
    /// colours (the solid's, each face's, all edges' and each edge's), so the node gives back
    /// exactly this body as it is drawn. How [`Document::add_solid`] puts a solid in a document.
    pub fn document_body(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_solid_body)(self.raw()) }, "document_solid_body")
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

    /// Edge `edge` (an index into [`Solid::edges`]) by what it is, fifteen doubles: its kind
    /// (line 0, circle 1, ellipse 2, B-spline 3, other 4), its midpoint (x y z), its unit
    /// tangent there (x y z), its length, the outward normals there of the two faces meeting
    /// on it (x y z each; an open sheet's rim gives the one face's twice), and its span --
    /// how far from the midpoint [`Solid::find_edge`] may find it on a resized solid.
    /// [`Solid::face_ref`]'s twin: take it before any move you apply to the solid. Refused
    /// for an edge past the table or one with no length to measure.
    pub fn edge_ref(&self, edge: u32) -> Result<[f64; 15]> {
        let mut out = [0.0; 15];
        if !unsafe { (self.api.cadaclysm_blacksmith_edge_ref)(self.raw(), edge, out.as_mut_ptr()) } {
            return Err(fail(self.api, "edge_ref"));
        }
        Ok(out)
    }

    /// The edge `edge_ref` (from [`Solid::edge_ref`]) refers to: of the edges of that kind
    /// passing within `tolerance` of its midpoint and running the same way, the one of
    /// nearest length; where none does (the solid was resized), the edge of that kind running
    /// the same way between faces facing the same two ways, the only one or the one clearly
    /// nearest, no farther than the span. `None` where the edge is gone. Refused for a
    /// reference that is not fifteen finite numbers or a `tolerance` not positive (Python's
    /// default is 1e-3).
    pub fn find_edge(&self, edge_ref: &[f64; 15], tolerance: f64) -> Result<Option<u32>> {
        let found = unsafe { (self.api.cadaclysm_blacksmith_find_edge)(self.raw(), edge_ref.as_ptr(), tolerance) };
        match found {
            -2 => Err(fail(self.api, "find_edge")),
            e if e < 0 => Ok(None),
            e => Ok(Some(e as u32)),
        }
    }

    /// How many vertices this solid has: its edges' ends, welded, in the order
    /// [`Solid::vertex_ref`] and [`Solid::find_vertex`] index.
    pub fn vertex_count(&self) -> Result<u32> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_vertex_count)(self.raw()) };
        if count == 0 && failed(self.api) {
            return Err(fail(self.api, "vertex_count"));
        }
        Ok(count)
    }

    /// Vertex `vertex` by where it is: `[x, y, z]`, in the solid's own coordinates. Refused
    /// for a vertex the solid does not have.
    pub fn vertex_ref(&self, vertex: u32) -> Result<[f64; 3]> {
        let mut out = [0.0; 3];
        if !unsafe { (self.api.cadaclysm_blacksmith_vertex_ref)(self.raw(), vertex, out.as_mut_ptr()) } {
            return Err(fail(self.api, "vertex_ref"));
        }
        Ok(out)
    }

    /// The vertex nearest `vertex_ref` (any point: a [`Solid::vertex_ref`], or one picked)
    /// within `tolerance`; `None` where no vertex is that near. Refused for a point that is
    /// not three finite numbers or a `tolerance` not positive (Python's default is 1e-3).
    pub fn find_vertex(&self, vertex_ref: &[f64; 3], tolerance: f64) -> Result<Option<u32>> {
        let found = unsafe { (self.api.cadaclysm_blacksmith_find_vertex)(self.raw(), vertex_ref.as_ptr(), tolerance) };
        match found {
            -2 => Err(fail(self.api, "find_vertex")),
            v if v < 0 => Ok(None),
            v => Ok(Some(v as u32)),
        }
    }

    // -- identity: ids on faces and edges, where each came from, and a verb's history

    /// This solid tracked: its faces numbered 1..n in face order and its edges 1..m in the
    /// edge table's order, each its own origin. Tracking is opt-in and rides on from here: a
    /// verb on a tracked solid gives a tracked result, its faces keeping the ids of the faces
    /// they lie on and naming those as their origins. A tracked solid comes back as it is.
    pub fn tracked(&self) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_solid_tracked)(self.raw()) }, "solid_tracked")
    }

    /// Whether this solid carries face and edge ids ([`Solid::tracked`], made from a tracked
    /// solid, or given an attribute).
    pub fn is_tracked(&self) -> Result<bool> {
        let tracked = unsafe { (self.api.cadaclysm_blacksmith_solid_is_tracked)(self.raw()) };
        if !tracked && failed(self.api) {
            return Err(fail(self.api, "solid_is_tracked"));
        }
        Ok(tracked)
    }

    /// An id the kernel gave back: `None` for 0 (untracked), the kernel's refusal where it left one.
    fn id_of(&self, id: u64, what: &str) -> Result<Option<u64>> {
        if id == 0 {
            return if failed(self.api) { Err(fail(self.api, what)) } else { Ok(None) };
        }
        Ok(Some(id))
    }

    /// An index found by id: `None` for `NONE` (no such id), the kernel's refusal where it
    /// left one.
    fn with_id(&self, found: u32, what: &str) -> Result<Option<u32>> {
        if found == NONE {
            return if failed(self.api) { Err(fail(self.api, what)) } else { Ok(None) };
        }
        Ok(Some(found))
    }

    fn origins(
        &self,
        count: u32,
        at: impl Fn(u32, &mut u32, &mut u64) -> bool,
        what: &str,
    ) -> Result<Vec<Origin>> {
        if count == NONE {
            return Err(fail(self.api, &format!("{what}_origin_count")));
        }
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count {
            let (mut operand, mut id) = (0u32, 0u64);
            if !at(i, &mut operand, &mut id) {
                return Err(fail(self.api, &format!("{what}_origin_at")));
            }
            out.push((operand, id));
        }
        Ok(out)
    }

    /// Face `face`'s id, `None` where this solid is untracked. An id stays with its face
    /// through every verb that keeps the face -- a move, a boolean, a fillet of another edge
    /// -- so it names "the same face, through my edits" within a session; a piece split off,
    /// a later operand's face whose id an earlier one already has, and a face on no input get
    /// fresh ids, the same run after run. Ids are not written to files: to find a face on a
    /// model rebuilt or read again, use [`Solid::face_ref`]. Refused for a face the solid
    /// does not have.
    pub fn face_id(&self, face: u32) -> Result<Option<u64>> {
        self.id_of(unsafe { (self.api.cadaclysm_blacksmith_face_id)(self.raw(), face) }, "face_id")
    }

    /// The face whose id is `id`, `None` where no face has it (an untracked solid, an id 0, a
    /// face a verb deleted).
    pub fn face_with_id(&self, id: u64) -> Result<Option<u32>> {
        self.with_id(unsafe { (self.api.cadaclysm_blacksmith_face_with_id)(self.raw(), id) }, "face_with_id")
    }

    /// The input faces face `face` came from, as [`Origin`]s: the face it lies on most first;
    /// empty for a face the verb generated (a fillet's round, a split's cut face) or an
    /// untracked solid; more than one for a face merged from several (a join's flush faces
    /// through [`Solid::merge_flush`] and [`Solid::origins_through`]). Refused for a face the
    /// solid does not have.
    pub fn face_origins(&self, face: u32) -> Result<Vec<Origin>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_face_origin_count)(self.raw(), face) };
        self.origins(
            count,
            |i, operand, id| unsafe { (self.api.cadaclysm_blacksmith_face_origin_at)(self.raw(), face, i, operand, id) },
            "face",
        )
    }

    /// Edge `edge`'s id (an index into [`Solid::edges`]), as [`Solid::face_id`].
    pub fn edge_id(&self, edge: u32) -> Result<Option<u64>> {
        self.id_of(unsafe { (self.api.cadaclysm_blacksmith_edge_id)(self.raw(), edge) }, "edge_id")
    }

    /// The edge whose id is `id`, `None` where no edge has it.
    pub fn edge_with_id(&self, id: u64) -> Result<Option<u32>> {
        self.with_id(unsafe { (self.api.cadaclysm_blacksmith_edge_with_id)(self.raw(), id) }, "edge_with_id")
    }

    /// The input edge edge `edge` lies on, as [`Solid::face_origins`]: one [`Origin`], or
    /// none for a new edge (edge merges are not seen).
    pub fn edge_origins(&self, edge: u32) -> Result<Vec<Origin>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_edge_origin_count)(self.raw(), edge) };
        self.origins(
            count,
            |i, operand, id| unsafe { (self.api.cadaclysm_blacksmith_edge_origin_at)(self.raw(), edge, i, operand, id) },
            "edge",
        )
    }

    /// This solid, made from `via` by a verb of one operand, with its face and edge origins
    /// read through `via`'s: each origin `(0, id)` replaced by the origins `via`'s face (edge)
    /// `id` has. Two steps then read as one: `joined.merge_flush()?.origins_through(&joined)?`
    /// names the join's two inputs, as operands 0 and 1, rather than the join's own faces --
    /// what Python's `join(merge=True)` does, and what [`Solid::history`] of the merge against
    /// the join's inputs needs. Ids, attributes and geometry stay this solid's; an untracked
    /// solid comes back as it is. Refused where `via` is untracked while this solid is not,
    /// or this solid was not made from `via` alone.
    pub fn origins_through(&self, via: &Solid) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_origins_through)(self.raw(), via.raw()) }, "origins_through")
    }

    fn read_history(
        &self,
        call: unsafe extern "C" fn(
            *const sys::CadaclysmBlacksmithSolid,
            *const *const sys::CadaclysmBlacksmithSolid,
            usize,
        ) -> *mut sys::CadaclysmBlacksmithHistory,
        inputs: &[&Solid],
        what: &str,
    ) -> Result<History> {
        let handles: Vec<*const sys::CadaclysmBlacksmithSolid> = inputs.iter().map(|s| s.raw()).collect();
        read_history(self.api, unsafe { call(self.raw(), handles.as_ptr(), handles.len()) }, what)
    }

    /// What the verb that made this solid did to the faces of `inputs` -- passed in its
    /// operand order (`a.cut(&b, t)?.history(&[&a, &b])`) -- read off this solid's ids and
    /// origins alone, as a [`History`]. Refused where this solid or an input is untracked,
    /// or an origin names an operand past the inputs.
    pub fn history(&self, inputs: &[&Solid]) -> Result<History> {
        self.read_history(self.api.cadaclysm_blacksmith_history, inputs, "history")
    }

    /// [`Solid::history`] for the edges, by edge id.
    pub fn edge_history(&self, inputs: &[&Solid]) -> Result<History> {
        self.read_history(self.api.cadaclysm_blacksmith_edge_history, inputs, "edge_history")
    }

    // -- attributes: text on a solid (written to STEP files) and on its faces (in memory)

    /// A new handle on this solid, equal to it: what `with_attributes` returns for no
    /// attributes (removing the empty key, which no solid has, copies the solid).
    fn copy(&self, what: &str) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_without_attribute)(self.raw(), b"\0".as_ptr().cast()) }, what)
    }

    /// An optional borrowed string: `None` for null with no `last_error`, copied out.
    fn optional_text(&self, raw: *const c_char, what: &str) -> Result<Option<String>> {
        if raw.is_null() {
            return if failed(self.api) { Err(fail(self.api, what)) } else { Ok(None) };
        }
        Ok(Some(unsafe { text(raw) }))
    }

    /// This solid's attributes, in key order. A solid's attributes go with it through every
    /// verb (a verb's result takes its first operand's) and are written to STEP files as
    /// user-defined attributes.
    pub fn attributes(&self) -> Result<BTreeMap<String, String>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_attribute_count)(self.raw()) };
        if count == 0 && failed(self.api) {
            return Err(fail(self.api, "attribute_count"));
        }
        attribute_map(
            self.api,
            count,
            |i| unsafe { (self.api.cadaclysm_blacksmith_attribute_key_at)(self.raw(), i) },
            |i| unsafe { (self.api.cadaclysm_blacksmith_attribute_value_at)(self.raw(), i) },
        )
    }

    /// Attribute `key`, `None` where this solid has none.
    pub fn attribute(&self, key: &str) -> Result<Option<String>> {
        let key = c_text("attribute: the key", key)?;
        self.optional_text(unsafe { (self.api.cadaclysm_blacksmith_attribute)(self.raw(), key.as_ptr()) }, "attribute")
    }

    /// This solid with attribute `key` set to `value`, over any it had: a new solid, tracked
    /// if this one was not. Keys and values are text (no NUL); an empty key is refused.
    pub fn with_attribute(&self, key: &str, value: &str) -> Result<Solid> {
        let (key, value) = (c_text("with_attribute: the key", key)?, c_text("with_attribute: the value", value)?);
        self.next(unsafe { (self.api.cadaclysm_blacksmith_with_attribute)(self.raw(), key.as_ptr(), value.as_ptr()) }, "with_attribute")
    }

    /// This solid with every attribute of `attributes` set, in key order (a key given twice:
    /// its last value). No attributes: a solid equal to this one.
    pub fn with_attributes<K: AsRef<str>, V: AsRef<str>>(&self, attributes: impl IntoIterator<Item = (K, V)>) -> Result<Solid> {
        let mut out: Option<Solid> = None;
        for (key, value) in by_key(attributes) {
            out = Some(out.as_ref().unwrap_or(self).with_attribute(key.as_ref(), value.as_ref())?);
        }
        out.map_or_else(|| self.copy("with_attributes"), Ok)
    }

    /// This solid without attribute `key`: a new solid, equal to this one where it had none.
    pub fn without_attribute(&self, key: &str) -> Result<Solid> {
        let key = c_text("without_attribute: the key", key)?;
        self.next(unsafe { (self.api.cadaclysm_blacksmith_without_attribute)(self.raw(), key.as_ptr()) }, "without_attribute")
    }

    /// Face `face`'s attributes, in key order. A face's attributes follow its id: kept
    /// through a verb, and copied to every face that names it as an origin (each piece of a
    /// split face has its parent's). They stay in memory: no file carries them. Refused for
    /// a face the solid does not have.
    pub fn face_attributes(&self, face: u32) -> Result<BTreeMap<String, String>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_face_attribute_count)(self.raw(), face) };
        if count == NONE {
            return Err(fail(self.api, "face_attribute_count"));
        }
        attribute_map(
            self.api,
            count,
            |i| unsafe { (self.api.cadaclysm_blacksmith_face_attribute_key_at)(self.raw(), face, i) },
            |i| unsafe { (self.api.cadaclysm_blacksmith_face_attribute_value_at)(self.raw(), face, i) },
        )
    }

    /// Face `face`'s attribute `key`, `None` where it has none. Refused for a face the solid
    /// does not have.
    pub fn face_attribute(&self, face: u32, key: &str) -> Result<Option<String>> {
        let key = c_text("face_attribute: the key", key)?;
        self.optional_text(unsafe { (self.api.cadaclysm_blacksmith_face_attribute)(self.raw(), face, key.as_ptr()) }, "face_attribute")
    }

    /// This solid with face `face`'s attribute `key` set to `value`: a new solid, tracked if
    /// this one was not. Refused as [`Solid::with_attribute`], and for a face the solid does
    /// not have.
    pub fn with_face_attribute(&self, face: u32, key: &str, value: &str) -> Result<Solid> {
        let (key, value) = (c_text("with_face_attribute: the key", key)?, c_text("with_face_attribute: the value", value)?);
        let raw = unsafe { (self.api.cadaclysm_blacksmith_with_face_attribute)(self.raw(), face, key.as_ptr(), value.as_ptr()) };
        self.next(raw, "with_face_attribute")
    }

    /// This solid with every attribute of `attributes` set on face `face`, in key order, as
    /// [`Solid::with_attributes`].
    pub fn with_face_attributes<K: AsRef<str>, V: AsRef<str>>(&self, face: u32, attributes: impl IntoIterator<Item = (K, V)>) -> Result<Solid> {
        let mut out: Option<Solid> = None;
        for (key, value) in by_key(attributes) {
            out = Some(out.as_ref().unwrap_or(self).with_face_attribute(face, key.as_ref(), value.as_ref())?);
        }
        out.map_or_else(|| self.copy("with_face_attributes"), Ok)
    }

    /// This solid without face `face`'s attribute `key`: a new solid, equal to this one where
    /// the face had none. Refused for a face the solid does not have.
    pub fn without_face_attribute(&self, face: u32, key: &str) -> Result<Solid> {
        let key = c_text("without_face_attribute: the key", key)?;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_without_face_attribute)(self.raw(), face, key.as_ptr()) };
        self.next(raw, "without_face_attribute")
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

    /// One thickness for face `face` of this solid alone, on a [`ThicknessGauge`] meshed at
    /// `tolerance` ([`DEFAULT_THICKNESS_TOLERANCE`], 0.01, is Python's default), used once and
    /// freed -- build the gauge yourself to ask more than once. `None` where nothing is found;
    /// see [`ThicknessGauge::thickness_at_face`]. Fails (`thickness_gauge_face: ...`) as it does.
    pub fn thickness_at_face(&self, face: u32, at: Option<[f64; 3]>, maximum: f64, tolerance: f64) -> Result<Option<FaceThickness>> {
        ThicknessGauge::new(&[self], tolerance)?.thickness_at_face(0, face, at, maximum)
    }

    /// An [`RTree`] over this solid's faces: one entry per face, its id the face index the other
    /// face calls take, its box holding the face (the box the boolean's broad phase pairs faces
    /// by, grown by a thousandth of the solid's extent). No faces give an empty tree. The tree is
    /// its own and outlives the solid.
    pub fn face_tree(&self) -> Result<RTree> {
        RTree::adopt(self.api, unsafe { (self.api.cadaclysm_blacksmith_solid_face_tree)(self.raw()) }, "solid_face_tree")
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

    /// What is wrong with this solid's body, as a [`HealthReport`] (the reader's type, shared):
    /// the free edges (the sides one face bounds) and the wires they chain into, each with its
    /// nearest partner and the gap to it; the features below `tolerance`; the loose edges; and
    /// what sewing would join and leave. Nothing moves. `tolerance` is an
    /// absolute length, by default (`None`, or a value that is not finite and positive) `1e-4`
    /// times the body's diagonal; the report says what was used. `mesh` also meshes the solid
    /// and reports where the mesh cracks ([`HealthReport::cracks`]); without it `cracks` is
    /// `None`.
    pub fn health(&self, tolerance: Option<f64>, mesh: bool) -> Result<HealthReport> {
        let api = self.api;
        let handle = unsafe { (api.cadaclysm_blacksmith_health)(self.raw(), tolerance.unwrap_or(f64::NAN), mesh) };
        let fail = || fail(api, "health");
        unsafe {
            health_from(
                handle,
                api.cadaclysm_blacksmith_health_free,
                api.cadaclysm_blacksmith_health_summary,
                [
                    api.cadaclysm_blacksmith_health_free_edges,
                    api.cadaclysm_blacksmith_health_wires,
                    api.cadaclysm_blacksmith_health_small,
                ],
                api.cadaclysm_blacksmith_health_crack_edges,
                &fail,
            )
        }
    }

    /// This solid with its small features removed, and what was done, as a new `Solid` and a
    /// [`HealReport`]; this one is left as it was, and the healed one keeps its name and
    /// colours. It heals what [`Solid::health`] lists as small at the same `tolerance`: short
    /// and collapsed edges, sliver and tiny faces, small holes. Every fix is a vertex merge, and
    /// an edge it moves records how far as its [`Solid::edge_tolerance`]. A guard compares the
    /// result's health with this one's and refuses fixes that made it worse
    /// ([`HealReport::guarded`]). `kinds` switches each kind of fix ([`HealKinds::default`]
    /// heals all three); a kind switched off is refused as `"toggled"`. `tolerance` as
    /// [`Solid::health`]'s.
    pub fn healed(&self, tolerance: Option<f64>, kinds: HealKinds) -> Result<(Solid, HealReport)> {
        let api = self.api;
        let handle = unsafe { (api.cadaclysm_blacksmith_healed)(self.raw(), tolerance.unwrap_or(f64::NAN), kinds.flags()) };
        let fail = || fail(api, "healed");
        unsafe {
            heal_from(
                handle,
                api.cadaclysm_blacksmith_heal_free,
                api.cadaclysm_blacksmith_heal_summary,
                api.cadaclysm_blacksmith_heal_fixes,
                api.cadaclysm_blacksmith_heal_refused,
                &fail,
                |h| Solid::wrap(api, (api.cadaclysm_blacksmith_heal_body)(h), "healed").ok(),
            )
        }
    }

    /// How far brep edge `edge` (as a [`HealFix`](crate::HealFix) or
    /// [`FreeEdge`](crate::FreeEdge) names one) may lie off its curve: 0 for an exact edge, the
    /// distance healing (or sewing) moved it where that is recorded, `None` when no trim names
    /// the id (an edge healing removed). A solid the kernel cannot read is its error.
    pub fn edge_tolerance(&self, edge: u32) -> Result<Option<f64>> {
        let t = unsafe { (self.api.cadaclysm_blacksmith_edge_tolerance)(self.raw(), edge) };
        if !t.is_nan() {
            return Ok(Some(t));
        }
        if failed(self.api) {
            return Err(fail(self.api, "edge_tolerance"));
        }
        Ok(None)
    }

    /// What this solid declares about its own precision, as [`Tolerances`]: read from its
    /// file, inherited through every verb from the loosest of its inputs, or set by
    /// [`with_tolerances`](Self::with_tolerances); `None` in a field nothing declared. A verb
    /// given a tolerance of 0 works at [`effective_tolerance`], which takes it into account.
    pub fn tolerances(&self) -> Result<Tolerances> {
        let (mut absolute, mut angular) = (f64::NAN, f64::NAN);
        if !unsafe { (self.api.cadaclysm_blacksmith_solid_tolerances)(self.raw(), &mut absolute, &mut angular) } {
            return Err(fail(self.api, "solid_tolerances"));
        }
        Ok(Tolerances::from_raw(absolute, angular))
    }

    /// A new solid: this one declaring `absolute` (a length) and `angular` (radians) instead of
    /// what it declared, its name, paint and marks kept. 0 (or NaN) declares nothing for that
    /// field; a negative or infinite value is the library's refusal.
    pub fn with_tolerances(&self, absolute: f64, angular: f64) -> Result<Solid> {
        self.next(unsafe { (self.api.cadaclysm_blacksmith_solid_with_tolerances)(self.raw(), absolute, angular) }, "solid_with_tolerances")
    }

    /// How loose this solid's vertex at `point` is, where its producer said (an OCCT `.brep`
    /// records one per vertex): the tolerance of the nearest recorded vertex within its own
    /// tolerance of `point`. `None` where none is recorded there.
    pub fn vertex_tolerance(&self, point: [f64; 3]) -> Result<Option<f64>> {
        let t = unsafe { (self.api.cadaclysm_blacksmith_vertex_tolerance)(self.raw(), point[0], point[1], point[2]) };
        if !t.is_nan() {
            return Ok(Some(t));
        }
        if failed(self.api) {
            return Err(fail(self.api, "vertex_tolerance"));
        }
        Ok(None)
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

    /// This solid's box on its principal axes. `accuracy` 0 or less asks for the box's own
    /// default, 1e-5.
    pub fn oriented_box(&self, accuracy: f64) -> Result<OrientedBox> {
        let mut raw = sys::CadaclysmBlacksmithOrientedBox::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_oriented_box)(self.raw(), accuracy, &mut raw) } {
            return Err(fail(self.api, "oriented_box"));
        }
        let a = raw.axes;
        Ok(OrientedBox {
            centre: raw.centre,
            axes: [[a[0], a[1], a[2]], [a[3], a[4], a[5]], [a[6], a[7], a[8]]],
            half: raw.half,
        })
    }

    /// The length of edge `edge` (the index [`Solid::edges`] and [`Solid::fillet`] use) to a
    /// relative `accuracy` in (0, 1); 0 or less asks for the default.
    pub fn edge_length(&self, edge: u32, accuracy: f64) -> Result<Length> {
        let mut raw = sys::CadaclysmBlacksmithLength::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_edge_length)(self.raw(), edge, accuracy, &mut raw) } {
            return Err(fail(self.api, "edge_length"));
        }
        Ok(raw.into())
    }

    /// The point `s` along edge `edge` from the start of its curve's range, to a relative
    /// `accuracy` in (0, 1); 0 or less asks for the default. `segment` is `None`.
    pub fn edge_point_at_length(&self, edge: u32, s: f64, accuracy: f64) -> Result<At> {
        let mut raw = sys::CadaclysmBlacksmithAt::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_edge_point_at_length)(self.raw(), edge, s, accuracy, &mut raw) } {
            return Err(fail(self.api, "edge_point_at_length"));
        }
        Ok(raw.into())
    }

    /// `n` (1 to 1,000,000) samples of edge `edge` equally far apart along it: `n` of a
    /// closed edge, `n + 1` of an open one.
    pub fn edge_divide_by_count(&self, edge: u32, n: u32, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_edge_divide_by_count)(self.raw(), edge, n, accuracy) };
        samples_of(self.api, raw, "edge_divide_by_count")
    }

    /// Samples of edge `edge` every `step` along it from its start; the last piece is kept
    /// short, and a closed edge's start is not repeated.
    pub fn edge_divide_by_length(&self, edge: u32, step: f64, accuracy: f64) -> Result<Vec<At>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_edge_divide_by_length)(self.raw(), edge, step, accuracy) };
        samples_of(self.api, raw, "edge_divide_by_length")
    }

    /// Where `point` is relative to this closed solid, within the absolute `tolerance`
    /// (positive and finite): `"outside"`, `"inside"` or `"on"`. Meshes the body every
    /// call; use [`Solid::classifier`] for more than a few points.
    pub fn contains(&self, point: [f64; 3], tolerance: f64) -> Result<&'static str> {
        let mut code = 0u32;
        if !unsafe { (self.api.cadaclysm_blacksmith_contains)(self.raw(), point.as_ptr(), tolerance, &mut code) } {
            return Err(fail(self.api, "contains"));
        }
        containment("contains", code)
    }

    /// A reusable classifier of this closed solid at the absolute `tolerance`.
    pub fn classifier(&self, tolerance: f64) -> Result<Classifier> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_classifier_new)(self.raw(), tolerance) };
        NonNull::new(raw).map(|handle| Classifier { handle, api: self.api }).ok_or_else(|| fail(self.api, "classifier_new"))
    }

    /// The closest points between this solid's boundary and `other`'s, to the absolute
    /// `tolerance` (positive and finite). Runs silent: no progress callback.
    pub fn closest(&self, other: &Solid, tolerance: f64) -> Result<Closest> {
        let mut raw = sys::CadaclysmBlacksmithClosest {
            distance: 0.0,
            on_a: [0.0; 3],
            on_b: [0.0; 3],
            kind_a: ptr::null(),
            index_a: 0,
            edge_a: u32::MAX,
            kind_b: ptr::null(),
            index_b: 0,
            edge_b: u32::MAX,
            refined: 0,
        };
        let ok = unsafe {
            (self.api.cadaclysm_blacksmith_closest)(self.raw(), other.raw(), tolerance, NO_PROGRESS, ptr::null_mut(), &mut raw)
        };
        if !ok {
            return Err(fail(self.api, "closest"));
        }
        // The kinds are static strings the library owns: copied, never freed.
        let kind = |p: *const c_char| if p.is_null() { String::new() } else { unsafe { text(p) } };
        let edge = |e: u32| (e != u32::MAX).then_some(e);
        Ok(Closest {
            distance: raw.distance,
            on_a: raw.on_a,
            on_b: raw.on_b,
            kind_a: kind(raw.kind_a),
            index_a: raw.index_a,
            edge_a: edge(raw.edge_a),
            kind_b: kind(raw.kind_b),
            index_b: raw.index_b,
            edge_b: edge(raw.edge_b),
            refined: raw.refined != 0,
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

    /// This solid as a Rhino `.3dm`'s bytes: its exact brep, named and coloured as the
    /// solid is -- see [`rhino3dm_bytes`].
    pub fn rhino3dm_bytes(&self, unit: Unit) -> Result<Vec<u8>> {
        rhino3dm_bytes(&[self], unit)
    }

    /// [`Solid::rhino3dm_bytes`] written to `path` by the library itself.
    pub fn write_3dm(&self, path: impl AsRef<FsPath>, unit: Unit) -> Result<()> {
        write_3dm(path, &[self], unit)
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
    /// The highest Z the item stands up to: the level a corner or undercut starts from, a
    /// hole's top, a slope's head, or for `too_deep` the flutes' reach.
    pub top: f64,
    /// The lowest Z the item stands down to: the floor a corner or undercut reaches, a hole's
    /// floor, a slope's foot, or for `too_deep` the level.
    pub bottom: f64,
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
                top: unsafe { (api.cadaclysm_blacksmith_report_top)(raw, i) },
                bottom: unsafe { (api.cadaclysm_blacksmith_report_bottom)(raw, i) },
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

    /// [`machine`](Self::machine) with several end mills, largest first: each later one
    /// cleans what the earlier ones left -- inside corners, regions too narrow for them,
    /// holes no drill matches. Everything else is as in `machine`. Fails for what the kernel
    /// refuses (no end mill, one not smaller than the one before, two sharing a number, a
    /// drill among them, a null drill, ...); the job changes only on success -- a refusal
    /// leaves it exactly as it was.
    #[allow(clippy::too_many_arguments)]
    pub fn machine_with(
        &mut self,
        part: &Solid,
        end_mills: &[&Tool],
        drills: &[Option<&Tool>],
        stepover: Option<f64>,
        stepdown: Option<f64>,
        skin: f64,
        peck: Option<f64>,
    ) -> Result<Report> {
        let ends: Vec<*const sys::CadaclysmBlacksmithTool> = end_mills.iter().map(|t| t.raw()).collect::<Vec<_>>();
        let ends_ptr = if ends.is_empty() { ptr::null() } else { ends.as_ptr() };
        let handles: Vec<*const sys::CadaclysmBlacksmithTool> = drills.iter().map(|t| t.map_or(ptr::null(), Tool::raw)).collect();
        let drills_ptr = if handles.is_empty() { ptr::null() } else { handles.as_ptr() };
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_job_machine_with)(
                self.raw(),
                part.raw(),
                ends_ptr,
                ends.len(),
                drills_ptr,
                handles.len(),
                stepover.unwrap_or(f64::NAN),
                stepdown.unwrap_or(f64::NAN),
                skin,
                peck.unwrap_or(f64::NAN),
            )
        };
        if raw.is_null() {
            return Err(fail(self.api, "job_machine_with"));
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

    /// Every pair of parts that penetrates, touches or lies within `clearance` of the other,
    /// as [`Clash`] rows in pair order, with each group placed at its matching frame in
    /// `frames` (as for [`Collider::check`], which answers overlap alone). `clearance` is zero
    /// or more, in model units: a pair apart by more than the collider's tolerance but less
    /// than it is `"too_close"`, within the tolerance `"touching"`. `share` as for `check`:
    /// the rows of the shares of one pose are disjoint and cover it. The collider keeps each
    /// part's closest mesh (at a third of its tolerance) for its lifetime once a pair needed
    /// one. Fails (`collider_clash: ...`) for a negative or non-finite `clearance`, the wrong
    /// number of frames or a `share` with `k >= n`.
    pub fn clash(&self, frames: &[Frame], clearance: f64, share: Option<(u32, u32)>) -> Result<Vec<Clash>> {
        let flat: Vec<f64> = frames.iter().flat_map(|f| f.raw()).collect();
        let (share_k, share_n) = share.unwrap_or((0, 0));
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_collider_clash)(self.raw(), flat.as_ptr(), frames.len() as u32, clearance, share_k, share_n)
        };
        clashes_of(self.api, raw, "collider_clash")
    }

    /// Every pair of parts that penetrates, touches or comes within `clearance` of the other
    /// anywhere on the path through `poses` -- not only at the poses -- as [`SweptClash`] rows
    /// in pair order. `poses` is two or more poses, each the `frames` [`Collider::clash`] takes
    /// (one frame per group). Between two poses each group moves rigidly about the centre of
    /// its rest box: that point on the straight line between its two places, the rotation
    /// turning at a steady rate the shorter way round. Time runs in pose units, pose `k` at
    /// time `k`.
    ///
    /// No moment where the true gap is below `clearance` less the collider's tolerance (for
    /// clearance 0: no penetration deeper than the tolerance) falls between two steps.
    /// `resolution` (in (0, 1], a fraction of a segment; Python's default 1e-3) is how closely
    /// an interval's end is found; `max_steps` (Python's default 100000) the pose-wise tests one
    /// pair may take -- a pair that needs more is a `"refused"` row. `share` as for
    /// [`Collider::check`], over the pairs whose swept boxes meet. The pose caches `check` and
    /// `clash` keep are neither read nor filled.
    ///
    /// Fails (`collider_swept_clash: ...`) for fewer than two poses, the wrong number of frames
    /// in a pose (a pose whose count differs from another's is refused here, in the kernel's
    /// words: `N frames for M groups`), a bad `clearance` or `resolution`, `max_steps` 0 or a
    /// `share` with `k >= n`.
    pub fn swept_clash(
        &self,
        poses: &[&[Frame]],
        clearance: f64,
        resolution: f64,
        max_steps: u32,
        share: Option<(u32, u32)>,
    ) -> Result<Vec<SweptClash>> {
        let frame_count = poses.first().map_or(0, |p| p.len());
        if poses.iter().any(|p| p.len() != frame_count) {
            // C reads every pose at one frame count: say the first pose that is off, in the
            // kernel's words.
            let groups = self.group_count() as usize;
            let n = poses.iter().map(|p| p.len()).find(|&n| n != groups).unwrap_or(frame_count);
            return Err(Error::new(format!("collider_swept_clash: {n} frames for {groups} groups")));
        }
        let flat: Vec<f64> = poses.iter().flat_map(|pose| pose.iter().flat_map(|f| f.raw())).collect();
        let (share_k, share_n) = share.unwrap_or((0, 0));
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_collider_swept_clash)(
                self.raw(),
                flat.as_ptr(),
                poses.len() as u32,
                frame_count as u32,
                clearance,
                resolution,
                max_steps,
                share_k,
                share_n,
            )
        };
        swept_clashes_of(self.api, raw, "collider_swept_clash")
    }
}

/// Keeps one clash call's answer ([`Collider::clash`], [`clash`]) alive for as long as any
/// [`Clash`] of it is: each row holds a clone of this (`Rc`), and the last one dropped frees
/// the handle -- as [`CollisionHit`]'s does, because [`Clash::solid`] and [`Clash::intersect`]
/// need the handle itself back.
struct ClashesHandle {
    handle: NonNull<sys::CadaclysmBlacksmithClashes>,
    api: &'static Api,
}

impl Drop for ClashesHandle {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_clashes_free)(self.handle.as_ptr()) }
    }
}

/// One pair [`clash`] or [`Collider::clash`] found, as plain data. `a`, `b` are the part
/// indices: for one set or a collider `a < b`; for two sets `a` indexes the first and `b` the
/// second. `kind` is `"penetrating"` (the volumes overlap), `"touching"` (the boundaries within
/// the tolerance of each other), `"too_close"` (apart by more than the tolerance but less than
/// the clearance) or `"refused"` (the pair could not be decided; `text` says why).
///
/// The feature fields are [`Closest`]'s, flat: what each point lies on (`"face"`, `"edge"` or
/// `"vertex"`), the kernel's id, and the [`Solid::edges`] index (`None` for a face, a vertex or
/// an edge the fillet table does not hold). For a penetrating or refused pair there is no
/// closest point: `kind_a` and `kind_b` are `"none"` and `index_*` and `edge_*` are `None`.
///
/// [`Clash::solid`] and [`Clash::intersect`] are built on demand, from the placement the pair
/// was found at; the answer of the call that found the rows is kept alive behind every row of
/// it -- past the collider and the solids -- until the last one is dropped, freeing it only
/// then. A row is neither `Send` nor `Sync` (its owner is shared by `Rc`), as [`CollisionHit`].
pub struct Clash {
    /// The first part's index: in the one set, or in the collider (then `a < b`); with two
    /// sets, an index into `parts`.
    pub a: u32,
    /// The second part's index; with two sets, an index into `others`.
    pub b: u32,
    /// `"penetrating"`, `"touching"`, `"too_close"` or `"refused"`.
    pub kind: String,
    /// The gap between the two boundaries; 0 for a penetrating or refused pair.
    pub distance: f64,
    /// A world point on part `a`: the closest of the pair; for a penetrating pair the centre
    /// of the overlap's world box; the origin for a refused one.
    pub on_a: [f64; 3],
    /// The matching world point on part `b`, as `on_a`.
    pub on_b: [f64; 3],
    /// What `on_a` lies on, as [`Closest::kind_a`]; `"none"` for a penetrating or refused pair.
    pub kind_a: String,
    /// The kernel's id for part `a`'s feature; `None` for a penetrating or refused pair.
    pub index_a: Option<u32>,
    /// Part `a`'s edge as the index [`Solid::edges`] uses, as [`Closest::edge_a`]; `None` for a
    /// face, a vertex, an edge the fillet table does not hold, and a penetrating or refused pair.
    pub edge_a: Option<u32>,
    /// What `on_b` lies on, as `kind_a`.
    pub kind_b: String,
    /// The kernel's id for part `b`'s feature, as `index_a`.
    pub index_b: Option<u32>,
    /// Part `b`'s edge, as `edge_a`.
    pub edge_b: Option<u32>,
    /// Whether the distance was measured on the exact surfaces; false for a penetrating or
    /// refused pair.
    pub refined: bool,
    /// The thinnest side of a penetrating pair's overlap box; 0 for any other.
    pub depth: f64,
    /// Why a refused pair could not be decided; empty otherwise.
    pub text: String,
    keeper: Rc<ClashesHandle>,
    index: u32,
}

impl fmt::Debug for Clash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Clash")
            .field("a", &self.a)
            .field("b", &self.b)
            .field("kind", &self.kind)
            .field("distance", &self.distance)
            .field("on_a", &self.on_a)
            .field("on_b", &self.on_b)
            .field("kind_a", &self.kind_a)
            .field("index_a", &self.index_a)
            .field("edge_a", &self.edge_a)
            .field("kind_b", &self.kind_b)
            .field("index_b", &self.index_b)
            .field("edge_b", &self.edge_b)
            .field("refined", &self.refined)
            .field("depth", &self.depth)
            .field("text", &self.text)
            .finish()
    }
}

impl Clash {
    /// Copied out of the C struct: the strings are read here and nowhere kept.
    ///
    /// # Safety
    /// `raw` as `cadaclysm_blacksmith_clashes_at` filled it, its handle still alive.
    unsafe fn from_raw(raw: &sys::CadaclysmBlacksmithClash, keeper: Rc<ClashesHandle>, index: u32) -> Clash {
        let (kind_a, kind_b) = unsafe { (text(raw.kind_a), text(raw.kind_b)) };
        // A `"none"` feature (penetrating, refused) has no index and no edge; otherwise the
        // edge is decoded as `Closest`'s is.
        let feature = |kind: &str, index: u32, edge: u32| {
            if kind == "none" {
                (None, None)
            } else {
                (Some(index), (edge != u32::MAX).then_some(edge))
            }
        };
        let (index_a, edge_a) = feature(&kind_a, raw.index_a, raw.edge_a);
        let (index_b, edge_b) = feature(&kind_b, raw.index_b, raw.edge_b);
        Clash {
            a: raw.a,
            b: raw.b,
            kind: unsafe { text(raw.kind) },
            distance: raw.distance,
            on_a: raw.on_a,
            on_b: raw.on_b,
            kind_a,
            index_a,
            edge_a,
            kind_b,
            index_b,
            edge_b,
            refined: raw.refined != 0,
            depth: raw.depth,
            text: unsafe { text(raw.text) },
            keeper,
            index,
        }
    }

    /// The exact shared volume of this penetrating pair, at the placement it was found at, as
    /// a new solid. Fails (`clashes_solid: ...`) for a pair that is not penetrating.
    pub fn solid(&self) -> Result<Solid> {
        let raw = unsafe { (self.keeper.api.cadaclysm_blacksmith_clashes_solid)(self.keeper.handle.as_ptr(), self.index) };
        Solid::wrap(self.keeper.api, raw, "clashes_solid")
    }

    /// Where this pair's two parts cross or coincide at the placement it was found at, as
    /// [`Solid::intersect`] reports it: a touching pair's shared face is an [`Overlap`]. Fails
    /// (`clashes_intersect: ...`) for a refused pair.
    pub fn intersect(&self) -> Result<Intersection> {
        let api = self.keeper.api;
        let found = unsafe { (api.cadaclysm_blacksmith_clashes_intersect)(self.keeper.handle.as_ptr(), self.index) };
        if found.is_null() {
            return Err(fail(api, "clashes_intersect"));
        }
        // SAFETY: `found` is a fresh, live intersection, given up here.
        unsafe { intersection_of(api, found) }
    }
}

/// A clash call's handle (null: fail as `what`) read out into rows, each keeping the handle
/// alive; with no rows it is freed at once.
fn clashes_of(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithClashes, what: &str) -> Result<Vec<Clash>> {
    let Some(handle) = NonNull::new(raw) else { return Err(fail(api, what)) };
    let count = unsafe { (api.cadaclysm_blacksmith_clashes_count)(handle.as_ptr()) };
    if count == 0 {
        unsafe { (api.cadaclysm_blacksmith_clashes_free)(handle.as_ptr()) };
        return Ok(Vec::new());
    }
    // From here the keeper frees the handle, on a failed read too.
    let keeper = Rc::new(ClashesHandle { handle, api });
    let mut rows = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut raw_row = sys::CadaclysmBlacksmithClash::default();
        if !unsafe { (api.cadaclysm_blacksmith_clashes_at)(keeper.handle.as_ptr(), i, &mut raw_row) } {
            return Err(fail(api, "clashes_at"));
        }
        rows.push(unsafe { Clash::from_raw(&raw_row, Rc::clone(&keeper), i) });
    }
    Ok(rows)
}

/// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
/// `others` -- that penetrates, touches or lies within `clearance` of the other, as [`Clash`]
/// rows in pair order, the solids as they stand. `tolerance` is the meshing tolerance, absolute
/// ([`DEFAULT_TOLERANCE`], 0.05, is Python's default). `allowed` pairs of part indices are never
/// tested (designed contacts); with `others` a pair is (index in `parts`, index in `others`).
/// In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again, then `a < b`).
///
/// Fails for an empty `others` (`clash: an empty set`; pass `None` for one set), and with the
/// kernel's words (`clash: ...`) for a negative or non-finite `clearance`, a `tolerance` not
/// positive and finite, an `allowed` index out of range or a part that is not a closed solid.
/// For the same parts moved pose after pose, build a [`Collider`] and ask [`Collider::clash`].
pub fn clash(parts: &[&Solid], others: Option<&[&Solid]>, clearance: f64, tolerance: f64, allowed: &[(u32, u32)]) -> Result<Vec<Clash>> {
    if others.is_some_and(|o| o.is_empty()) {
        return Err(Error::new("clash: an empty set"));
    }
    let api = api()?;
    let first: Vec<*const sys::CadaclysmBlacksmithSolid> = parts.iter().map(|s| s.raw()).collect();
    let second: Option<Vec<*const sys::CadaclysmBlacksmithSolid>> = others.map(|o| o.iter().map(|s| s.raw()).collect());
    let (second_ptr, second_count) = match &second {
        Some(v) => (v.as_ptr(), v.len() as u32),
        None => (ptr::null(), 0),
    };
    let allowed_flat: Vec<u32> = allowed.iter().flat_map(|&(a, b)| [a, b]).collect();
    let allowed_ptr = if allowed_flat.is_empty() { ptr::null() } else { allowed_flat.as_ptr() };
    let raw = unsafe {
        (api.cadaclysm_blacksmith_clash)(
            first.as_ptr(),
            first.len() as u32,
            second_ptr,
            second_count,
            tolerance,
            clearance,
            allowed_ptr,
            allowed.len() as u32,
        )
    };
    clashes_of(api, raw, "clash")
}

/// One pair [`swept_clash`] or [`Collider::swept_clash`] found, as plain data. `a`, `b` are the
/// part indices, as [`Clash`]'s. `first_time` is the first time the pair came within the
/// clearance, in pose units (for a refused pair, the time it was refused at), and `first` the
/// [`Clash`] there -- its kind, distance, points and features, with [`Clash::solid`] and
/// [`Clash::intersect`] rebuilding the contact at that time. `intervals` are the time ranges
/// the pair stays in clash, `(start, end)`, ascending and disjoint (none for a refused pair).
///
/// The rows' `first`s share one clashes answer of their own, kept alive as [`Clash`]'s is --
/// past the collider, the solids and the call -- so a row is neither `Send` nor `Sync`.
#[derive(Debug)]
pub struct SweptClash {
    /// The first part's index, as [`Clash::a`].
    pub a: u32,
    /// The second part's index, as [`Clash::b`].
    pub b: u32,
    /// The first time the pair came within the clearance, in pose units; for a refused pair
    /// the time it was refused at.
    pub first_time: f64,
    /// The pose-wise clash at `first_time`.
    pub first: Clash,
    /// The time ranges the pair stays in clash, `(start, end)`, ascending and disjoint; empty
    /// for a refused pair.
    pub intervals: Vec<(f64, f64)>,
}

/// Frees a swept clashes handle when the read is done, on a failed read too.
struct SweptClashesHandle {
    handle: NonNull<sys::CadaclysmBlacksmithSweptClashes>,
    api: &'static Api,
}

impl Drop for SweptClashesHandle {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_swept_clashes_free)(self.handle.as_ptr()) }
    }
}

/// A swept clash call's handle (null: fail as `what`) read out into rows and freed; each row's
/// `first` a [`Clash`] of the handle's first rows, which keep their own clashes handle alive.
fn swept_clashes_of(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSweptClashes, what: &str) -> Result<Vec<SweptClash>> {
    let Some(handle) = NonNull::new(raw) else { return Err(fail(api, what)) };
    let swept = SweptClashesHandle { handle, api };
    let h = swept.handle.as_ptr();
    let count = unsafe { (api.cadaclysm_blacksmith_swept_clashes_count)(h) };
    if count == 0 {
        return Ok(Vec::new());
    }
    let firsts = clashes_of(api, unsafe { (api.cadaclysm_blacksmith_swept_clashes_firsts)(h) }, "swept_clashes_firsts")?;
    let mut rows = Vec::with_capacity(count as usize);
    for (i, first) in (0..count).zip(firsts) {
        let mut raw_row = sys::CadaclysmBlacksmithSweptClash::default();
        if !unsafe { (api.cadaclysm_blacksmith_swept_clashes_at)(h, i, &mut raw_row) } {
            return Err(fail(api, "swept_clashes_at"));
        }
        let mut intervals = Vec::with_capacity(raw_row.interval_count as usize);
        for k in 0..raw_row.interval_count {
            let mut span = [0.0f64; 2];
            if !unsafe { (api.cadaclysm_blacksmith_swept_clashes_interval)(h, i, k, span.as_mut_ptr()) } {
                return Err(fail(api, "swept_clashes_interval"));
            }
            intervals.push((span[0], span[1]));
        }
        rows.push(SweptClash { a: raw_row.a, b: raw_row.b, first_time: raw_row.first_time, first, intervals });
    }
    Ok(rows)
}

/// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of the
/// other set -- that penetrates, touches or comes within `clearance` of the other anywhere on a
/// path, as [`SweptClash`] rows. Each part is its own group: pose `k` of `poses` is one frame
/// per part of `parts`; `others` is the other set's solids and its poses together, pose `k` of
/// them one frame per solid (as many poses as `poses`). The motion between poses, the
/// guarantee, `resolution` and `max_steps` are [`Collider::swept_clash`]'s. `tolerance` is the
/// meshing tolerance, absolute ([`DEFAULT_TOLERANCE`], 0.05, is Python's default). `allowed`
/// pairs of part indices are never tested; with `others` a pair is (index in `parts`, index in
/// the other set). In a row `a` indexes `parts` and `b` the other set (or `parts` again).
///
/// Fails, in the wrapper (`swept_clash: ...`), for pose counts that differ between the two sets,
/// a pose with the wrong number of frames (set a first) and an empty other set (pass `None` for
/// one set); and with the kernel's words for fewer than two poses, a bad frame, `tolerance`,
/// `clearance` or `resolution`, `max_steps` 0, an `allowed` index out of range or a part that is
/// not a closed solid.
#[allow(clippy::too_many_arguments)]
pub fn swept_clash(
    parts: &[&Solid],
    poses: &[&[Frame]],
    others: Option<(&[&Solid], &[&[Frame]])>,
    clearance: f64,
    tolerance: f64,
    resolution: f64,
    max_steps: u32,
    allowed: &[(u32, u32)],
) -> Result<Vec<SweptClash>> {
    // C reads each set's poses at its part count: the kernel's own checks, in its order.
    if let Some((_, other_poses)) = others {
        if other_poses.len() != poses.len() {
            return Err(Error::new(format!("swept_clash: {} poses for set a, {} for set b", poses.len(), other_poses.len())));
        }
    }
    let (second, other_poses) = others.unwrap_or((&[], &[]));
    for (name, set, n) in [("a", poses, parts.len()), ("b", other_poses, second.len())] {
        if let Some((k, pose)) = set.iter().enumerate().find(|(_, pose)| pose.len() != n) {
            return Err(Error::new(format!("swept_clash: pose {k} of set {name} has {} frames for {n} parts", pose.len())));
        }
    }
    if others.is_some_and(|(o, _)| o.is_empty()) {
        return Err(Error::new("swept_clash: an empty set"));
    }
    let api = api()?;
    let flatten = |set: &[&[Frame]]| -> Vec<f64> { set.iter().flat_map(|pose| pose.iter().flat_map(|f| f.raw())).collect() };
    let first: Vec<*const sys::CadaclysmBlacksmithSolid> = parts.iter().map(|s| s.raw()).collect();
    let poses_a = flatten(poses);
    let second: Option<(Vec<*const sys::CadaclysmBlacksmithSolid>, Vec<f64>)> =
        others.map(|(o, p)| (o.iter().map(|s| s.raw()).collect(), flatten(p)));
    let (second_ptr, second_count, poses_b_ptr) = match &second {
        Some((solids, flat)) => (solids.as_ptr(), solids.len() as u32, flat.as_ptr()),
        None => (ptr::null(), 0, ptr::null()),
    };
    let allowed_flat: Vec<u32> = allowed.iter().flat_map(|&(a, b)| [a, b]).collect();
    let allowed_ptr = if allowed_flat.is_empty() { ptr::null() } else { allowed_flat.as_ptr() };
    let raw = unsafe {
        (api.cadaclysm_blacksmith_swept_clash)(
            first.as_ptr(),
            first.len() as u32,
            poses_a.as_ptr(),
            second_ptr,
            second_count,
            poses_b_ptr,
            poses.len() as u32,
            tolerance,
            clearance,
            resolution,
            max_steps,
            allowed_ptr,
            allowed.len() as u32,
        )
    };
    swept_clashes_of(api, raw, "swept_clash")
}

// ---- wall thickness -----------------------------------------------------------------

/// One wall-thickness reading on a solid ([`ThicknessGauge::thickness`],
/// [`ThicknessGauge::thickness_at`], [`thickness`]). `point` lies on face `face` of body `body`
/// (the body's index in the gauge): at vertex `vertex` of that body's measuring mesh
/// ([`ThicknessGauge::mesh`]), or `vertex` `None` for a reading at a point. `thickness` is the
/// nearest-opposing-wall rule (the nearest triangle that faces against one of the vertex's own
/// faces, with the vertex behind it) on the measuring mesh, to `opposite` on face
/// `opposite_face` of body `opposite_body`; `knife` marks a knife edge (thickness 0,
/// `opposite` == `point`). `exact_opposite` is `opposite` moved onto its exact face where its
/// foot lies within the tolerance and inside the face's trims, `exact_thickness` the distance
/// to it. `sphere` is the diameter of the largest ball tangent at `point` that holds none of
/// the surfaces, `None` where none under the maximum does (0 on a knife edge).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Thickness {
    pub body: u32,
    pub vertex: Option<u32>,
    pub face: u32,
    pub point: [f64; 3],
    pub thickness: f64,
    pub opposite: [f64; 3],
    pub opposite_body: u32,
    pub opposite_face: u32,
    pub knife: bool,
    pub exact_thickness: f64,
    pub exact_opposite: [f64; 3],
    pub sphere: Option<f64>,
}

impl From<&sys::CadaclysmBlacksmithThickness> for Thickness {
    fn from(r: &sys::CadaclysmBlacksmithThickness) -> Thickness {
        Thickness {
            body: r.body,
            vertex: (r.vertex != NONE).then_some(r.vertex),
            face: r.face,
            point: r.point,
            thickness: r.thickness,
            opposite: r.opposite,
            opposite_body: r.opposite_body,
            opposite_face: r.opposite_face,
            knife: r.knife,
            exact_thickness: r.exact_thickness,
            exact_opposite: r.exact_opposite,
            sphere: (!r.sphere.is_nan()).then_some(r.sphere),
        }
    }
}

/// A face's thickness, found ([`ThicknessGauge::thickness_at_face`],
/// [`Solid::thickness_at_face`]; where nothing is found those answer `None`): `thickness` the
/// median of the face's vertex readings (or the reading at `at`), `min` and `max` their
/// extremes, `uniform` whether `max - min` is within the gauge's tolerance.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FaceThickness {
    pub thickness: f64,
    pub min: f64,
    pub max: f64,
    pub uniform: bool,
}

/// A body's measuring mesh ([`ThicknessGauge::mesh`]), copied out of the gauge: `positions` and
/// `normals` (unit, outward) one point per vertex -- a reading's `vertex` indexes them; no
/// vertex is shared between two faces -- `triangles` three vertex indices each, and `faces` the
/// B-rep face of each triangle.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ThicknessMesh {
    pub positions: Vec<[f64; 3]>,
    pub normals: Vec<[f64; 3]>,
    pub triangles: Vec<[u32; 3]>,
    pub faces: Vec<u32>,
}

/// One reading on a plain mesh ([`mesh_thickness`]): vertex `vertex` of mesh `mesh`, at
/// `point`, reads `thickness` to `opposite` on triangle `opposite_triangle` of mesh
/// `opposite_mesh` (both indices within that mesh). `knife`: a knife edge, thickness 0 and
/// `opposite` == `point`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MeshThickness {
    pub mesh: u32,
    pub vertex: u32,
    pub thickness: f64,
    pub point: [f64; 3],
    pub opposite: [f64; 3],
    pub opposite_mesh: u32,
    pub opposite_triangle: u32,
    pub knife: bool,
}

impl From<&sys::CadaclysmBlacksmithMeshThickness> for MeshThickness {
    fn from(r: &sys::CadaclysmBlacksmithMeshThickness) -> MeshThickness {
        MeshThickness {
            mesh: r.mesh,
            vertex: r.vertex,
            thickness: r.thickness,
            point: r.point,
            opposite: r.opposite,
            opposite_mesh: r.opposite_mesh,
            opposite_triangle: r.opposite_triangle,
            knife: r.knife,
        }
    }
}

/// Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle
/// that faces against one of its own faces, with the vertex behind it) over `solids`, measured
/// against each other: each solid meshed once at `tolerance` -- absolute, in model units
/// ([`DEFAULT_THICKNESS_TOLERANCE`], 0.01, is Python's default) -- then asked as often as
/// needed. A reading's `body` is the solid's index in `solids`. The gauge keeps its own
/// reference to the bodies, so it answers on after they are dropped. Dropping it frees the
/// handle.
pub struct ThicknessGauge {
    handle: NonNull<sys::CadaclysmBlacksmithThicknessGauge>,
    api: &'static Api,
}

unsafe impl Send for ThicknessGauge {}

impl Drop for ThicknessGauge {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for ThicknessGauge {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ThicknessGauge({:p})", self.handle)
    }
}

/// The meshing tolerance Python's `ThicknessGauge` and `thickness` default to.
pub const DEFAULT_THICKNESS_TOLERANCE: f64 = 0.01;

impl ThicknessGauge {
    /// `solids` meshed at `tolerance`. Fails (`thickness_gauge_new: ...`) for a `tolerance`
    /// not positive and finite.
    pub fn new(solids: &[&Solid], tolerance: f64) -> Result<ThicknessGauge> {
        let api = api()?;
        let handles: Vec<*const sys::CadaclysmBlacksmithSolid> = solids.iter().map(|s| s.raw()).collect();
        let raw = unsafe { (api.cadaclysm_blacksmith_thickness_gauge_new)(handles.as_ptr(), handles.len() as u32, tolerance) };
        NonNull::new(raw).map(|handle| ThicknessGauge { handle, api }).ok_or_else(|| fail(api, "thickness_gauge_new"))
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithThicknessGauge {
        self.handle.as_ptr()
    }

    /// How many bodies the gauge measures.
    pub fn body_count(&self) -> u32 {
        unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_body_count)(self.raw()) }
    }

    /// The tolerance the gauge meshed its bodies at.
    pub fn tolerance(&self) -> f64 {
        unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_tolerance)(self.raw()) }
    }

    /// One reading per measuring-mesh vertex that has one within `maximum` (positive and
    /// finite), by body then vertex; vertices whose interior angle is under `sharp_angle`
    /// radians (zero or more; Python defaults to 0) are knife edges. Fails
    /// (`thickness_gauge_measure: ...`) for a bad limit.
    pub fn thickness(&self, maximum: f64, sharp_angle: f64) -> Result<Vec<Thickness>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_measure)(self.raw(), maximum, sharp_angle) };
        thicknesses_of(self.api, raw, "thickness_gauge_measure")
    }

    /// The reading at `point`'s foot on face `face` of body `body` (its `vertex` `None`), or
    /// `None` where the foot lies off the face or the wall is thicker than `maximum`. Fails
    /// (`thickness_gauge_at: ...`) for a body or face past the end, a point not finite or a
    /// bad limit.
    pub fn thickness_at(&self, body: u32, face: u32, point: [f64; 3], maximum: f64, sharp_angle: f64) -> Result<Option<Thickness>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_at)(self.raw(), body, face, point.as_ptr(), maximum, sharp_angle) };
        Ok(thicknesses_of(self.api, raw, "thickness_gauge_at")?.into_iter().next())
    }

    /// One thickness for face `face` of body `body`: measured at `at`'s foot on the face or,
    /// with `at` `None`, over the face's vertices; the other bodies are measured with it.
    /// `None` where nothing is found (nothing reads under `maximum`, or `at`'s foot lies off
    /// the face). Fails (`thickness_gauge_face: ...`) for a body or face past the end, an
    /// `at` not finite or a bad maximum.
    pub fn thickness_at_face(&self, body: u32, face: u32, at: Option<[f64; 3]>, maximum: f64) -> Result<Option<FaceThickness>> {
        let at_ptr = at.as_ref().map_or(ptr::null(), |p| p.as_ptr());
        let mut out = sys::CadaclysmBlacksmithFaceThickness::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_face)(self.raw(), body, face, at_ptr, maximum, &mut out) } {
            return Err(fail(self.api, "thickness_gauge_face"));
        }
        Ok(out.found.then_some(FaceThickness { thickness: out.thickness, min: out.min, max: out.max, uniform: out.uniform }))
    }

    /// Body `body`'s measuring mesh, copied out (it outlives the gauge). Fails
    /// (`thickness_gauge_mesh: ...`) for a body past the end.
    pub fn mesh(&self, body: u32) -> Result<ThicknessMesh> {
        let mut raw = sys::CadaclysmBlacksmithThicknessMesh::default();
        if !unsafe { (self.api.cadaclysm_blacksmith_thickness_gauge_mesh)(self.raw(), body, &mut raw) } {
            return Err(fail(self.api, "thickness_gauge_mesh"));
        }
        let (n, t) = (raw.vertex_count as usize, raw.triangle_count as usize);
        // Borrowed from the gauge, which `self` keeps alive through the copies below.
        let (positions, normals, indices, faces) = unsafe {
            (
                if n == 0 { &[][..] } else { std::slice::from_raw_parts(raw.positions, 3 * n) },
                if n == 0 { &[][..] } else { std::slice::from_raw_parts(raw.normals, 3 * n) },
                if t == 0 { &[][..] } else { std::slice::from_raw_parts(raw.indices, 3 * t) },
                if t == 0 { &[][..] } else { std::slice::from_raw_parts(raw.faces, t) },
            )
        };
        Ok(ThicknessMesh {
            positions: positions.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
            normals: normals.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
            triangles: indices.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect(),
            faces: faces.to_vec(),
        })
    }
}

/// A thicknesses handle (null: fail as `what`) read out into rows and freed, on every path.
fn thicknesses_of(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithThicknesses, what: &str) -> Result<Vec<Thickness>> {
    let Some(handle) = NonNull::new(raw) else { return Err(fail(api, what)) };
    let rows = (|| {
        let count = unsafe { (api.cadaclysm_blacksmith_thicknesses_count)(handle.as_ptr()) };
        let mut rows = Vec::with_capacity(count as usize);
        let mut row = sys::CadaclysmBlacksmithThickness::default();
        for i in 0..count {
            if !unsafe { (api.cadaclysm_blacksmith_thicknesses_at)(handle.as_ptr(), i, &mut row) } {
                return Err(fail(api, "thicknesses_at"));
            }
            rows.push(Thickness::from(&row));
        }
        Ok(rows)
    })();
    unsafe { (api.cadaclysm_blacksmith_thicknesses_free)(handle.as_ptr()) };
    rows
}

/// `ThicknessGauge::new(solids, tolerance)?.thickness(maximum, sharp_angle)` on a gauge used
/// once and freed: every reading within `maximum` on the solids, measured against each other.
/// `tolerance` defaults to [`DEFAULT_THICKNESS_TOLERANCE`] elsewhere; `sharp_angle` to 0.
pub fn thickness(solids: &[&Solid], maximum: f64, sharp_angle: f64, tolerance: f64) -> Result<Vec<Thickness>> {
    ThicknessGauge::new(solids, tolerance)?.thickness(maximum, sharp_angle)
}

/// The nearest-opposing-wall rule on plain meshes measured against each other: each mesh a
/// `(positions, triangles)` pair -- points and triples of indices into its own points. One
/// reading per vertex that has one within `maximum` (positive and finite), by mesh then
/// vertex; `sharp_angle` as for [`ThicknessGauge::thickness`] (zero or more). Fails
/// (`mesh_thickness: ...`) for a mesh too large to count, a triangle past its mesh, a
/// position not finite or a bad limit.
pub fn mesh_thickness(meshes: &[(&[[f64; 3]], &[[u32; 3]])], maximum: f64, sharp_angle: f64) -> Result<Vec<MeshThickness>> {
    let api = api()?;
    let mut positions: Vec<f64> = Vec::new();
    let mut indices: Vec<u32> = Vec::new();
    let mut vertex_counts: Vec<u32> = Vec::with_capacity(meshes.len());
    let mut triangle_counts: Vec<u32> = Vec::with_capacity(meshes.len());
    for (m, (points, triangles)) in meshes.iter().enumerate() {
        let (Ok(v), Ok(t)) = (u32::try_from(points.len()), u32::try_from(triangles.len())) else {
            return Err(Error::new(format!("mesh_thickness: mesh {m} is too large")));
        };
        positions.extend(points.iter().flatten());
        indices.extend(triangles.iter().flatten());
        vertex_counts.push(v);
        triangle_counts.push(t);
    }
    let raw = unsafe {
        (api.cadaclysm_blacksmith_mesh_thickness)(
            positions.as_ptr(),
            vertex_counts.as_ptr(),
            indices.as_ptr(),
            triangle_counts.as_ptr(),
            meshes.len() as u32,
            maximum,
            sharp_angle,
        )
    };
    let Some(handle) = NonNull::new(raw) else { return Err(fail(api, "mesh_thickness")) };
    let rows = (|| {
        let count = unsafe { (api.cadaclysm_blacksmith_mesh_thicknesses_count)(handle.as_ptr()) };
        let mut rows = Vec::with_capacity(count as usize);
        let mut row = sys::CadaclysmBlacksmithMeshThickness::default();
        for i in 0..count {
            if !unsafe { (api.cadaclysm_blacksmith_mesh_thicknesses_at)(handle.as_ptr(), i, &mut row) } {
                return Err(fail(api, "mesh_thicknesses_at"));
            }
            rows.push(MeshThickness::from(&row));
        }
        Ok(rows)
    })();
    unsafe { (api.cadaclysm_blacksmith_mesh_thicknesses_free)(handle.as_ptr()) };
    rows
}

// ---- the R-tree -------------------------------------------------------------------

/// One entry [`RTree::within`] or [`RTree::nearest`] found: its `id` and the `distance` from
/// the point to its box (0 inside it). Python's `(id, distance)`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RTreeHit {
    pub id: u32,
    pub distance: f64,
}

/// Two entries whose boxes meet: `a` of the tree asked and `b` of the other
/// ([`RTree::overlaps`]), or `a <= b` ([`RTree::self_overlaps`]). Python's `(a, b)`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RTreePair {
    pub a: u32,
    pub b: u32,
}

/// A spatial index over boxes with ids (an R\*-tree): [`RTree::search`] a box for the entries
/// it meets, [`RTree::within`] / [`RTree::nearest`] a point for the closest,
/// [`RTree::overlaps`] / [`RTree::self_overlaps`] for every pair of boxes that meet. Ids are the
/// caller's own and may repeat; an entry is an id and its [`Aabb`], and the same `(id, box)`
/// twice is two entries. Touching boxes meet. A point stands for a zero box
/// ([`RTree::insert_point`], [`RTree::remove_point`]). Answers come in a fixed order: search
/// ids ascending, within / nearest by distance then id, pairs ascending. The tree changes in
/// place through `&mut self`; it may move to another thread but not be shared between two
/// (`Send`, not `Sync`). Dropping it frees the handle. Python's `RTree`.
pub struct RTree {
    handle: NonNull<sys::CadaclysmBlacksmithRTree>,
    api: &'static Api,
}

// SAFETY: the handle is the tree alone -- no thread-local or thread-bound state, no borrowed
// memory -- so it may be freed or used from whichever thread holds it. It is not `Sync`: the
// library does not lock a tree, so calls on one must not overlap, which `&self` queries from
// two threads would allow.
unsafe impl Send for RTree {}

impl Drop for RTree {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_rtree_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for RTree {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "RTree({} entries)", self.len())
    }
}

/// A box as the C ABI's 6 doubles, `[minx, miny, minz, maxx, maxy, maxz]`.
fn rtree_words(b: &Aabb) -> [f64; 6] {
    [b.lo[0], b.lo[1], b.lo[2], b.hi[0], b.hi[1], b.hi[2]]
}

/// A count at the C boundary, refused by `what` past what a `uint32_t` holds.
fn rtree_count(n: usize, what: &str, items: &str) -> Result<u32> {
    u32::try_from(n).map_err(|_| Error::new(format!("{what}: {n} {items} is more than 4294967295")))
}

/// Frees a query's hit list on every exit.
struct RTreeHitsGuard {
    raw: *mut sys::CadaclysmBlacksmithRTreeHits,
    api: &'static Api,
}

impl Drop for RTreeHitsGuard {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_rtree_hits_free)(self.raw) };
    }
}

/// Frees a query's pair list on every exit.
struct RTreePairsGuard {
    raw: *mut sys::CadaclysmBlacksmithRTreePairs,
    api: &'static Api,
}

impl Drop for RTreePairsGuard {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_rtree_pairs_free)(self.raw) };
    }
}

/// The hits of a list the library handed back (null: the last error), copied out; the list is
/// freed on every path, a failing read's too (its reason read first).
fn rtree_hits(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithRTreeHits, what: &str) -> Result<Vec<RTreeHit>> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let list = RTreeHitsGuard { raw, api };
    let count = unsafe { (api.cadaclysm_blacksmith_rtree_hits_count)(list.raw) };
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut hit = sys::CadaclysmBlacksmithRTreeHit::default();
        if !unsafe { (api.cadaclysm_blacksmith_rtree_hits_at)(list.raw, i, &mut hit) } {
            // `fail` runs before `list` drops, so the reason is read before the free.
            return Err(fail(api, "rtree_hits_at"));
        }
        out.push(RTreeHit { id: hit.id, distance: hit.distance });
    }
    Ok(out)
}

/// The pairs of a list the library handed back, as [`rtree_hits`] reads hits.
fn rtree_pairs(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithRTreePairs, what: &str) -> Result<Vec<RTreePair>> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let list = RTreePairsGuard { raw, api };
    let count = unsafe { (api.cadaclysm_blacksmith_rtree_pairs_count)(list.raw) };
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut pair = sys::CadaclysmBlacksmithRTreePair::default();
        if !unsafe { (api.cadaclysm_blacksmith_rtree_pairs_at)(list.raw, i, &mut pair) } {
            return Err(fail(api, "rtree_pairs_at"));
        }
        out.push(RTreePair { a: pair.a, b: pair.b });
    }
    Ok(out)
}

impl RTree {
    fn adopt(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithRTree, what: &str) -> Result<RTree> {
        match NonNull::new(raw) {
            Some(handle) => Ok(RTree { handle, api }),
            None => Err(fail(api, what)),
        }
    }

    /// An empty tree.
    pub fn new() -> Result<RTree> {
        let api = api()?;
        RTree::adopt(api, unsafe { (api.cadaclysm_blacksmith_rtree_new)() }, "rtree_new")
    }

    /// A tree over `(id, box)` entries at once, packed (sort-tile-recursive): fuller and faster
    /// to query than the same entries inserted one by one. The first entry whose box is not a
    /// box (a NaN, an infinity, `lo` above `hi`) is refused, by index.
    pub fn from_boxes(entries: &[(u32, Aabb)]) -> Result<RTree> {
        let api = api()?;
        let n = rtree_count(entries.len(), "rtree_from_boxes", "entries")?;
        let ids: Vec<u32> = entries.iter().map(|e| e.0).collect();
        let boxes: Vec<f64> = entries.iter().flat_map(|e| rtree_words(&e.1)).collect();
        let (ids_at, boxes_at) = if entries.is_empty() { (ptr::null(), ptr::null()) } else { (ids.as_ptr(), boxes.as_ptr()) };
        RTree::adopt(api, unsafe { (api.cadaclysm_blacksmith_rtree_from_boxes)(ids_at, boxes_at, n) }, "rtree_from_boxes")
    }

    /// A tree over `points`, each a zero box whose id is its index. The first point with a NaN
    /// or infinite coordinate is refused, by index.
    pub fn from_points(points: &[[f64; 3]]) -> Result<RTree> {
        let api = api()?;
        let n = rtree_count(points.len(), "rtree_from_points", "points")?;
        let at = if points.is_empty() { ptr::null() } else { points.as_ptr().cast::<f64>() };
        RTree::adopt(api, unsafe { (api.cadaclysm_blacksmith_rtree_from_points)(at, n) }, "rtree_from_points")
    }

    /// A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one entry per
    /// triangle of `triangles` (three indices into `positions`), its id the triangle's index, its
    /// box its three corners' box. The first corner past the points or at a point with a NaN or
    /// infinite coordinate is refused, by triangle and point; points no triangle uses are not
    /// checked.
    pub fn from_triangles(positions: &[[f64; 3]], triangles: &[[u32; 3]]) -> Result<RTree> {
        let api = api()?;
        let np = rtree_count(positions.len(), "rtree_from_triangles", "points")?;
        let nt = rtree_count(triangles.len(), "rtree_from_triangles", "triangles")?;
        let at = if positions.is_empty() { ptr::null() } else { positions.as_ptr().cast::<f64>() };
        let idx = if triangles.is_empty() { ptr::null() } else { triangles.as_ptr().cast::<u32>() };
        RTree::adopt(api, unsafe { (api.cadaclysm_blacksmith_rtree_from_triangles)(at, np, idx, nt) }, "rtree_from_triangles")
    }

    /// How many entries the tree holds.
    pub fn len(&self) -> usize {
        unsafe { (self.api.cadaclysm_blacksmith_rtree_count)(self.handle.as_ptr()) as usize }
    }

    /// Whether the tree holds no entry.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The union of every entry's box, or `None` for an empty tree.
    pub fn bounds(&self) -> Result<Option<Aabb>> {
        if self.is_empty() {
            return Ok(None);
        }
        let mut out = [0.0f64; 6];
        if !unsafe { (self.api.cadaclysm_blacksmith_rtree_bounds)(self.handle.as_ptr(), out.as_mut_ptr()) } {
            return Err(fail(self.api, "rtree_bounds"));
        }
        Ok(Some(Aabb::new([out[0], out[1], out[2]], [out[3], out[4], out[5]])))
    }

    /// Add the entry `(id, bx)`. A box that is not a box is refused and leaves the tree as it was.
    pub fn insert(&mut self, id: u32, bx: &Aabb) -> Result<()> {
        let words = rtree_words(bx);
        if !unsafe { (self.api.cadaclysm_blacksmith_rtree_insert)(self.handle.as_ptr(), id, words.as_ptr()) } {
            return Err(fail(self.api, "rtree_insert"));
        }
        Ok(())
    }

    /// Add the entry `(id, point)`, the point a zero box: Python's `insert` with a point. A point
    /// not finite is refused and leaves the tree as it was.
    pub fn insert_point(&mut self, id: u32, point: [f64; 3]) -> Result<()> {
        if !unsafe { (self.api.cadaclysm_blacksmith_rtree_insert_point)(self.handle.as_ptr(), id, point.as_ptr()) } {
            return Err(fail(self.api, "rtree_insert_point"));
        }
        Ok(())
    }

    /// Take out one entry equal to `(id, bx)` -- the box it was inserted with, compared
    /// coordinate by coordinate -- and say whether there was one: `false`, not an error, when
    /// there is none. With duplicates, one goes per call. A box that is not a box is refused.
    pub fn remove(&mut self, id: u32, bx: &Aabb) -> Result<bool> {
        self.remove_words(id, rtree_words(bx))
    }

    /// [`RTree::remove`] for an entry inserted as a point (its zero box): Python's `remove` with
    /// a point.
    pub fn remove_point(&mut self, id: u32, point: [f64; 3]) -> Result<bool> {
        self.remove_words(id, [point[0], point[1], point[2], point[0], point[1], point[2]])
    }

    fn remove_words(&mut self, id: u32, words: [f64; 6]) -> Result<bool> {
        if unsafe { (self.api.cadaclysm_blacksmith_rtree_remove)(self.handle.as_ptr(), id, words.as_ptr()) } {
            return Ok(true);
        }
        if failed(self.api) {
            return Err(fail(self.api, "rtree_remove"));
        }
        Ok(false)
    }

    /// The ids of every entry whose box meets `bx` (touching counts), ascending, one per entry.
    /// A box that is not a box is refused.
    pub fn search(&self, bx: &Aabb) -> Result<Vec<u32>> {
        let words = rtree_words(bx);
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_search)(self.handle.as_ptr(), words.as_ptr()) };
        Ok(rtree_hits(self.api, raw, "rtree_search")?.into_iter().map(|h| h.id).collect())
    }

    /// Every entry whose box is within `r` of `point` (Euclidean, 0 inside the box; exactly `r`
    /// counts), by distance then id. A point not finite or an `r` negative or NaN is refused.
    pub fn within(&self, point: [f64; 3], r: f64) -> Result<Vec<RTreeHit>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_within)(self.handle.as_ptr(), point.as_ptr(), r) };
        rtree_hits(self.api, raw, "rtree_within")
    }

    /// The `k` entries whose boxes are nearest `point`, by distance then id (the smaller ids win
    /// a tie); all of them when `k` is over the count. A point not finite or a `k` above
    /// 1,000,000 is refused.
    pub fn nearest(&self, point: [f64; 3], k: u32) -> Result<Vec<RTreeHit>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_nearest)(self.handle.as_ptr(), point.as_ptr(), k) };
        rtree_hits(self.api, raw, "rtree_nearest")
    }

    /// Every entry whose box the ray `origin + t * direction`, `0 <= t <= max_t`, meets, as hits
    /// whose `distance` is the `t` where the ray enters the box (0 when `origin` is inside it), by
    /// `t` then id. Touching counts. `t` is in units of `direction`'s length, which is not
    /// normalised; `max_t` may be `f64::INFINITY` (Python's default). An origin or direction not
    /// finite, a zero direction, or a `max_t` negative or NaN is refused.
    pub fn ray(&self, origin: [f64; 3], direction: [f64; 3], max_t: f64) -> Result<Vec<RTreeHit>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_ray)(self.handle.as_ptr(), origin.as_ptr(), direction.as_ptr(), max_t) };
        rtree_hits(self.api, raw, "rtree_ray")
    }

    /// Every pair `(a, b)`, `a` an entry of this tree and `b` one of `other` (which may be this
    /// tree), whose boxes are at most `slack` apart on every axis (0: touching), ascending. A
    /// `slack` negative or NaN is refused.
    pub fn overlaps(&self, other: &RTree, slack: f64) -> Result<Vec<RTreePair>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_overlaps)(self.handle.as_ptr(), other.handle.as_ptr(), slack) };
        rtree_pairs(self.api, raw, "rtree_overlaps")
    }

    /// Every unordered pair of distinct entries at most `slack` apart, once each as `(smaller
    /// id, larger id)`, ascending -- an id paired with itself only where two entries share it. A
    /// `slack` negative or NaN is refused.
    pub fn self_overlaps(&self, slack: f64) -> Result<Vec<RTreePair>> {
        let raw = unsafe { (self.api.cadaclysm_blacksmith_rtree_self_overlaps)(self.handle.as_ptr(), slack) };
        rtree_pairs(self.api, raw, "rtree_self_overlaps")
    }
}

/// Refuses, as the kernel's `closest_points` / `k_neighbors` do, the first hay point and then
/// the first needle that is not finite, by index.
fn finite_points(call: &str, hay: &[[f64; 3]], needles: &[[f64; 3]]) -> Result<()> {
    for (name, points) in [("hay", hay), ("needle", needles)] {
        if let Some(i) = points.iter().position(|p| !p.iter().all(|v| v.is_finite())) {
            return Err(Error::new(format!("{call}: {name} point {i} is not finite")));
        }
    }
    Ok(())
}

/// For each of `needles`, the indices of the `hay` points within `limit` of it, by distance then
/// index -- one [`RTree`] over the hay answers every needle. A `limit` negative or NaN, then the
/// first hay point and the first needle not finite, by index, are refused.
pub fn closest_points(hay: &[[f64; 3]], needles: &[[f64; 3]], limit: f64) -> Result<Vec<Vec<usize>>> {
    if limit.is_nan() || limit < 0.0 {
        return Err(Error::new(format!("closest_points: limit {limit} is not a distance")));
    }
    finite_points("closest_points", hay, needles)?;
    let tree = RTree::from_points(hay)?;
    needles
        .iter()
        .map(|&p| Ok(tree.within(p, limit)?.into_iter().map(|h| h.id as usize).collect()))
        .collect()
}

/// For each of `needles`, the indices of the `k` nearest `hay` points, by distance then index
/// (all of them when `k` is over the hay count). The first hay point and the first needle not
/// finite, by index, then a `k` above 1,000,000, are refused.
pub fn k_neighbors(hay: &[[f64; 3]], needles: &[[f64; 3]], k: u32) -> Result<Vec<Vec<usize>>> {
    finite_points("k_neighbors", hay, needles)?;
    if k > 1_000_000 {
        return Err(Error::new(format!("k_neighbors: k {k} is not at most 1000000")));
    }
    let tree = RTree::from_points(hay)?;
    needles
        .iter()
        .map(|&p| Ok(tree.nearest(p, k)?.into_iter().map(|h| h.id as usize).collect()))
        .collect()
}

// ---- regions ----------------------------------------------------------------------

/// One side of one face, as a [`Region`] lists its sides: `face` the face's index in the solid,
/// `sense` +1 for the side its normal points to, -1 for the other. A solid's inside is behind
/// its faces, at -1. Python's `FaceSide`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FaceSide {
    pub face: u32,
    pub sense: i32,
}

/// One region of space a solid's faces bound ([`Solid::regions`]): its `index` (0 the infinite
/// region, whose `finite` is false), the box round the faces bounding it (`bounds`, Python's
/// `box`, a word Rust reserves), its `sides` ascending by face then sense, and its `shells` --
/// 1, plus one per void inside it. [`Solid::region_solid`] takes a finite one as a solid of its
/// own. Python's `Region`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Region {
    pub index: u32,
    pub finite: bool,
    pub bounds: Aabb,
    pub sides: Vec<FaceSide>,
    pub shells: u32,
}

/// Frees a regions list on every exit.
struct RegionsGuard {
    raw: *mut sys::CadaclysmBlacksmithRegions,
    api: &'static Api,
}

impl Drop for RegionsGuard {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_regions_free)(self.raw) };
    }
}

/// The regions of a list the library handed back (null: the last error), copied out; the list
/// is freed on every path, a failing read's too (its reason read first).
fn regions_of(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithRegions) -> Result<Vec<Region>> {
    if raw.is_null() {
        return Err(fail(api, "regions"));
    }
    let list = RegionsGuard { raw, api };
    let count = unsafe { (api.cadaclysm_blacksmith_regions_count)(list.raw) };
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let mut region = sys::CadaclysmBlacksmithRegion::default();
        if !unsafe { (api.cadaclysm_blacksmith_regions_at)(list.raw, i, &mut region) } {
            // `fail` runs before `list` drops, so the reason is read before the free.
            return Err(fail(api, "regions_at"));
        }
        let mut sides = Vec::with_capacity(region.sides as usize);
        for k in 0..region.sides {
            let mut side = sys::CadaclysmBlacksmithFaceSide::default();
            if !unsafe { (api.cadaclysm_blacksmith_regions_side_at)(list.raw, i, k, &mut side) } {
                return Err(fail(api, "regions_side_at"));
            }
            sides.push(FaceSide { face: side.face, sense: side.sense });
        }
        out.push(Region {
            index: i,
            finite: region.finite != 0,
            bounds: Aabb::new(region.min, region.max),
            sides,
            shells: region.shells,
        });
    }
    Ok(out)
}

// ---- the interpolator -------------------------------------------------------------

/// How an [`Interpolator`] reads between samples -- Paul Bourke's formulas, in the notation `mu`
/// the fraction past sample `i`, `y0 ... y3` the samples at `i - 1 ... i + 2`. Every mode returns
/// the sample itself at a whole `t`. Valued as the C constants
/// `CADACLYSM_BLACKSMITH_INTERPOLATE_*`; `Linear` is the default. Python's mode names.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum InterpolatorMode {
    /// The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
    Nearest = sys::CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST,
    /// Straight between the samples either side of `t`: `y1 + (y2 - y1) mu`.
    #[default]
    Linear = sys::CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR,
    /// Linear at `(1 - cos(pi mu)) / 2` instead of `mu`: an ease, flat at every sample.
    Cosine = sys::CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE,
    /// Bourke's cubic over the four samples about `t`: through every sample, not C1, and it
    /// does not reproduce a straight ramp.
    Cubic = sys::CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC,
    /// The Catmull-Rom spline over the four samples about `t`: through every sample, C1, its
    /// tangent at each `(y2 - y0) / 2`.
    CatmullRom = sys::CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM,
}

/// A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is sample
/// 2, `t = 2.5` halfway between samples 2 and 3. Animation keys, a value along a pattern, a
/// smoothed profile of measurements.
///
/// [`Interpolator::new`] takes numbers (dimension 1), [`Interpolator::rows`] equal-length rows
/// -- 2D or 3D points, or vectors of any dimension, each component read on its own. Every value
/// comes back as a `Vec<f64>` of [`Interpolator::dimension`] numbers. An open list clamps `t` to
/// `[0, len - 1]` and stops on its end samples; a cyclic one wraps `t` with period `len`
/// (`t = -0.5` is halfway between the last sample and the first). See [`InterpolatorMode`].
///
/// It never changes once made, so it may be shared between threads (`Send` and `Sync`).
/// Dropping it frees the handle. Python's `Interpolator`.
pub struct Interpolator {
    handle: NonNull<sys::CadaclysmBlacksmithInterpolator>,
    api: &'static Api,
    dimension: usize,
}

// SAFETY: the handle is the samples alone, made once by `interpolator_new` and never written
// after it -- every other call takes it `const` and only reads it (the C source says so: "it may
// be read from any number of threads at once") -- with no thread-bound state, so it may be
// freed from whichever thread holds it and read from several at once.
unsafe impl Send for Interpolator {}
unsafe impl Sync for Interpolator {}

impl Drop for Interpolator {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_interpolator_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Interpolator {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let cyclic = if self.cyclic() { ", cyclic" } else { "" };
        write!(f, "Interpolator({} samples of {}{cyclic})", self.len(), self.dimension)
    }
}

/// A count at the C boundary, refused by `what` past what a `uint32_t` holds.
fn interpolator_count(n: usize, what: &str, items: &str) -> Result<u32> {
    u32::try_from(n).map_err(|_| Error::new(format!("{what}: {n} {items} is more than 4294967295")))
}

impl Interpolator {
    /// An interpolator over numbers, dimension 1; `cyclic` wraps `t` round the list, else it is
    /// clamped to the first and last samples. No samples, or a sample NaN or infinite (by its
    /// index), is refused.
    pub fn new(samples: &[f64], cyclic: bool) -> Result<Interpolator> {
        Interpolator::build(samples, samples.len(), 1, cyclic)
    }

    /// An interpolator over rows of numbers, each a sample of `row.len()` numbers -- points or
    /// vectors -- every component read on its own: `&[[f64; 3]]`, `&[Vec<f64>]` and the like.
    /// Rows of unequal length are refused before the call (`interpolator: samples differ in
    /// length`), then what [`Interpolator::new`] refuses.
    pub fn rows<R: AsRef<[f64]>>(rows: &[R], cyclic: bool) -> Result<Interpolator> {
        let dimension = rows.first().map_or(1, |r| r.as_ref().len());
        if rows.iter().any(|r| r.as_ref().len() != dimension) {
            let lengths: std::collections::BTreeSet<usize> = rows.iter().map(|r| r.as_ref().len()).collect();
            return Err(Error::new(format!("interpolator: samples differ in length ({:?})", lengths.into_iter().collect::<Vec<_>>())));
        }
        let flat: Vec<f64> = rows.iter().flat_map(|r| r.as_ref().iter().copied()).collect();
        Interpolator::build(&flat, rows.len(), dimension, cyclic)
    }

    fn build(flat: &[f64], count: usize, dimension: usize, cyclic: bool) -> Result<Interpolator> {
        let api = api()?;
        let n = interpolator_count(count, "interpolator_new", "samples")?;
        let d = interpolator_count(dimension, "interpolator_new", "numbers a sample")?;
        let at = if flat.is_empty() { ptr::null() } else { flat.as_ptr() };
        let raw = unsafe { (api.cadaclysm_blacksmith_interpolator_new)(at, n, d, cyclic) };
        match NonNull::new(raw) {
            Some(handle) => Ok(Interpolator { handle, api, dimension }),
            None => Err(fail(api, "interpolator_new")),
        }
    }

    fn raw(&self) -> *const sys::CadaclysmBlacksmithInterpolator {
        self.handle.as_ptr()
    }

    /// How many samples.
    pub fn len(&self) -> usize {
        unsafe { (self.api.cadaclysm_blacksmith_interpolator_count)(self.raw()) as usize }
    }

    /// Always false: an interpolator holds at least one sample.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// How many numbers a sample holds, and so every value read.
    pub fn dimension(&self) -> usize {
        unsafe { (self.api.cadaclysm_blacksmith_interpolator_dimension)(self.raw()) as usize }
    }

    /// Whether `t` wraps round the list (else it is clamped to the ends).
    pub fn cyclic(&self) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_interpolator_cyclic)(self.raw()) }
    }

    /// The value at the fractional index `t` by `mode`, [`Interpolator::dimension`] numbers. A
    /// `t` NaN or infinite is refused.
    pub fn at(&self, t: f64, mode: InterpolatorMode) -> Result<Vec<f64>> {
        let mut out = vec![0.0; self.dimension];
        let room = interpolator_count(out.len(), "interpolator_at", "numbers")?;
        if !unsafe { (self.api.cadaclysm_blacksmith_interpolator_at)(self.raw(), t, mode as u32, out.as_mut_ptr(), room) } {
            return Err(fail(self.api, "interpolator_at"));
        }
        Ok(out)
    }

    /// The values at every `t` of `ts` by `mode`, as [`Interpolator::at`] reads each, in one
    /// call. A value of `t` NaN or infinite (by its index), or more than 1,000,000 of them, is
    /// refused; no `ts` answers an empty list.
    pub fn sample(&self, ts: &[f64], mode: InterpolatorMode) -> Result<Vec<Vec<f64>>> {
        if ts.is_empty() {
            return Ok(Vec::new());
        }
        let n = interpolator_count(ts.len(), "interpolator_sample", "values")?;
        let d = self.dimension;
        let room = ts.len().saturating_mul(d);
        let room = interpolator_count(room, "interpolator_sample", "numbers")?;
        let mut out = vec![0.0; room as usize];
        if !unsafe { (self.api.cadaclysm_blacksmith_interpolator_sample)(self.raw(), ts.as_ptr(), n, mode as u32, out.as_mut_ptr(), room) } {
            return Err(fail(self.api, "interpolator_sample"));
        }
        Ok(out.chunks_exact(d).map(<[f64]>::to_vec).collect())
    }

    /// The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
    pub fn nearest(&self, t: f64) -> Result<Vec<f64>> {
        self.at(t, InterpolatorMode::Nearest)
    }

    /// Straight between the two samples either side of `t`.
    pub fn linear(&self, t: f64) -> Result<Vec<f64>> {
        self.at(t, InterpolatorMode::Linear)
    }

    /// Between the two samples either side of `t` on a cosine ease, flat at every sample.
    pub fn cosine(&self, t: f64) -> Result<Vec<f64>> {
        self.at(t, InterpolatorMode::Cosine)
    }

    /// Bourke's cubic over the four samples about `t`, through every sample.
    pub fn cubic(&self, t: f64) -> Result<Vec<f64>> {
        self.at(t, InterpolatorMode::Cubic)
    }

    /// The Catmull-Rom spline over the four samples about `t`: through every sample, C1.
    pub fn catmull_rom(&self, t: f64) -> Result<Vec<f64>> {
        self.at(t, InterpolatorMode::CatmullRom)
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

    /// A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when
    /// no faces are given): each face becomes quads round a new point, and an unpicked face
    /// beside them takes the new edge points as corners. The whole cage keeps its smooth
    /// surface exactly. The new cage selects the new faces.
    pub fn subdivide(&self, faces: &[u32]) -> Result<Subd> {
        self.edit(
            unsafe { (self.api.cadaclysm_blacksmith_subd_subdivide)(self.raw(), faces.as_ptr(), faces.len() as u32) },
            "subd_subdivide",
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

// ---- the 2D constraint sketcher ---------------------------------------------------

// The C ABI's codes, by position; Rust speaks the names, as Python does.
const SKETCH_ENTITY_KINDS: [&str; 5] = ["point", "line", "circle", "arc", "free_curve"];
const SKETCH_CONSTRAINT_KINDS: [&str; 27] = [
    "coincident",
    "point_on_line",
    "point_on_circle",
    "horizontal",
    "vertical",
    "parallel",
    "perpendicular",
    "collinear",
    "tangent",
    "tangent_at_end",
    "concentric",
    "equal_length",
    "equal_radius",
    "midpoint",
    "symmetric",
    "fix",
    "distance",
    "point_line_distance",
    "line_distance",
    "circle_line_distance",
    "circle_distance",
    "horizontal_distance",
    "vertical_distance",
    "length",
    "angle",
    "radius",
    "diameter",
];
const SKETCH_SENSES: [&str; 3] = ["auto", "positive", "negative"];
const SKETCH_ENDS: [&str; 2] = ["start", "end"];
const SKETCH_STATUSES: [&str; 3] = ["converged", "conflicting", "diverged"];
const SKETCH_STATES: [&str; 3] = ["under", "full", "over"];

// `sketch_dof_list`'s and `sketch_dof_part_list`'s `which`.
const SKETCH_DOF_REDUNDANT: u32 = 0;
const SKETCH_DOF_CONFLICTING: u32 = 1;
const SKETCH_DOF_FREE_ENTITIES: u32 = 2;
const SKETCH_PART_CONSTRAINTS: u32 = 0;
const SKETCH_PART_REDUNDANT: u32 = 1;
const SKETCH_PART_CONFLICTING: u32 = 2;
const SKETCH_PART_FREE_ENTITIES: u32 = 3;

/// The name at `code` in `table`; `NONE` or a code past the end is the library's reason.
fn sketch_named(api: &Api, table: &[&'static str], code: u32, what: &str) -> Result<&'static str> {
    table.get(code as usize).copied().ok_or_else(|| fail(api, what))
}

/// The code of `name` in `table`, or an error naming the call and the parameter.
fn sketch_code(table: &[&str], name: &str, call: &str, param: &str) -> Result<u32> {
    match table.iter().position(|known| *known == name) {
        Some(code) => Ok(code as u32),
        None => {
            let quoted: Vec<String> = table.iter().map(|known| format!("'{known}'")).collect();
            Err(Error::new(format!("{call}: {param} must be one of {}, not '{name}'", quoted.join(", "))))
        }
    }
}

/// A count or a code the library sends as a double (a report's status and iterations, a
/// diagnosis's free, state, part count and params): the whole number it holds, or an error
/// naming the call when it holds a fraction, NaN, a negative or more than an `i32` (the
/// bound every wrapper's exact conversion shares) -- never truncated.
fn sketch_whole(value: f64, what: &str) -> Result<u32> {
    if value >= 0.0 && value <= f64::from(i32::MAX) && value.fract() == 0.0 {
        Ok(value as u32)
    } else {
        Err(Error::new(format!("{what}: the library answered {value}, not a whole number in range")))
    }
}

/// A drag's point ids in ascending order and their targets flat beside them: every wrapper
/// sends a drag in that one order, so the same moves solve the same way however they are
/// listed. A point given twice is refused (the library would keep only one of its targets).
fn sketch_moves(moves: &[(u32, [f64; 2])]) -> Result<(Vec<u32>, Vec<f64>)> {
    let mut sorted = moves.to_vec();
    sorted.sort_by_key(|(id, _)| *id);
    if let Some(w) = sorted.windows(2).find(|w| w[0].0 == w[1].0) {
        return Err(Error::new(format!("sketch_drag: point {} given twice", w[0].0)));
    }
    Ok((sorted.iter().map(|(id, _)| *id).collect(), sorted.iter().flat_map(|(_, to)| *to).collect()))
}

/// What a solve did, as plain data ([`Sketch::solve`], [`Sketch::drag`],
/// [`Sketch::set_value`], [`Sketch::set_driving`] and [`Sketch::update_reference`] return
/// one). `status` is `"converged"`, `"conflicting"` or `"diverged"`; `ids` the constraints a
/// conflict ran into, or the worst ones of a diverged solve (empty when it converged).
#[derive(Clone, Debug, PartialEq)]
pub struct SolveReport {
    pub status: &'static str,
    /// The most solver iterations any one part took.
    pub iterations: u32,
    /// The largest constraint residual left, scaled by the sketch's size.
    pub max_residual: f64,
    pub ids: Vec<u32>,
}

impl SolveReport {
    /// Whether `status` is `"converged"`.
    pub fn converged(&self) -> bool {
        self.status == "converged"
    }
}

/// One independent part of a diagnosed sketch ([`Dof::parts`]): its unknowns (`params`), how
/// many stay `free`, its `state` (`"under"`, `"full"` or `"over"`), its `constraints`, the
/// `redundant` and `conflicting` ones among them, and its `free_entities`.
#[derive(Clone, Debug, PartialEq)]
pub struct PartDof {
    pub params: u32,
    pub free: u32,
    pub state: &'static str,
    pub constraints: Vec<u32>,
    pub redundant: Vec<u32>,
    pub conflicting: Vec<u32>,
    pub free_entities: Vec<u32>,
}

/// A sketch's degrees of freedom ([`Sketch::diagnose`]): how many are `free`, its `state`
/// (`"under"`, `"full"` or `"over"`), the `redundant` and `conflicting` constraint ids, the
/// `free_entities` that can still move, and the independent `parts` it splits into.
#[derive(Clone, Debug, PartialEq)]
pub struct Dof {
    pub free: u32,
    pub state: &'static str,
    pub redundant: Vec<u32>,
    pub conflicting: Vec<u32>,
    pub free_entities: Vec<u32>,
    pub parts: Vec<PartDof>,
}

/// A 2D sketch of points, lines, circles, arcs and free curves held by geometric
/// constraints and dimensions, solved on request. Entities and constraints are named by
/// `u32` ids. Entity kinds are `"point"`, `"line"`, `"circle"`, `"arc"` and `"free_curve"`;
/// a constraint's kind is the name of the method that added it (`"point_line_distance"`,
/// ...), but for [`radius_of`](Sketch::radius_of), whose kind is `"radius"`. Senses are
/// `"auto"`, `"positive"` or `"negative"`; ends `"start"` or `"end"`. Rust has no default
/// arguments: every argument is stated (Python's are `driving` true, sense `"auto"`, end
/// `"start"`).
///
/// A refused call returns an [`Error`] with the library's text and, as its
/// [`ids`](Error::ids), the ids the refusal names: the constraints a new constraint, value
/// or reference conflicts with, or the entities still using a point (empty when it names
/// none). The [`SolveReport`]s of [`solve`](Sketch::solve), [`drag`](Sketch::drag),
/// [`set_value`](Sketch::set_value), [`set_driving`](Sketch::set_driving) and
/// [`update_reference`](Sketch::update_reference) carry a report's ids the same way.
///
/// Every method takes `&self`, as [`Assembly`]'s reads do, because the library keeps the
/// sketch's state; `Send` but not `Sync`, so one thread at a time holds it. Dropping it frees
/// the handle instead of an explicit close.
///
/// ```compile_fail,E0277
/// fn shared<T: Sync>() {}
/// shared::<cadaclysm_sdk::blacksmith::Sketch>(); // error: a sketch is not for two threads at once
/// ```
pub struct Sketch {
    handle: NonNull<sys::CadaclysmBlacksmithSketch>,
    api: &'static Api,
}

// SAFETY: the library takes one thread at a time per sketch, and `NonNull` keeps `Sketch`
// `!Sync`, so no two threads can hold a reference to it together; moving it between threads
// between calls is fine (nothing in it is thread-local).
unsafe impl Send for Sketch {}

impl Drop for Sketch {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_sketch_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Sketch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Sketch({:p})", self.handle)
    }
}

impl Sketch {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithSketch, what: &str) -> Result<Sketch> {
        NonNull::new(raw).map(|handle| Sketch { handle, api }).ok_or_else(|| fail(api, what))
    }

    /// The raw pointer every call takes -- `*mut`, since the calls that edit and the ones
    /// that lend a list both want it; a call that only reads passes it where a `*const` is
    /// asked for, which a `*mut` coerces to.
    fn raw(&self) -> *mut sys::CadaclysmBlacksmithSketch {
        self.handle.as_ptr()
    }

    /// A list the library lends until the next call on this sketch, copied out. Null is a
    /// refusal: the library's reason, no ids.
    fn lent(&self, what: &str, p: *const u32, n: usize) -> Result<Vec<u32>> {
        if p.is_null() {
            return Err(fail(self.api, what));
        }
        Ok(if n == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(p, n) }.to_vec() })
    }

    /// A borrowed list asked for by `call` (which receives the count's out-parameter),
    /// copied out before anything else is called on the sketch.
    fn list(&self, what: &str, call: impl FnOnce(&mut usize) -> *const u32) -> Result<Vec<u32>> {
        let mut n = 0usize;
        let p = call(&mut n);
        self.lent(what, p, n)
    }

    /// A refusal that may name ids: the reason first (the wasm shims clear it on the next
    /// call), then `report_ids`.
    fn refused(&self, what: &str) -> Error {
        let reason = fail(self.api, what);
        let mut n = 0usize;
        let p = unsafe { (self.api.cadaclysm_blacksmith_sketch_report_ids)(self.raw(), &mut n) };
        let ids = if p.is_null() || n == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(p, n) }.to_vec() };
        reason.with_ids(ids)
    }

    /// An id the library handed back (`NONE`: its reason, no ids).
    fn id(&self, got: u32, what: &str) -> Result<u32> {
        if got == NONE {
            Err(fail(self.api, what))
        } else {
            Ok(got)
        }
    }

    /// The report a re-solving call filled in (`done` false: refused, with ids).
    fn solved(&self, done: bool, report: &[f64; 3], what: &str) -> Result<SolveReport> {
        if !done {
            return Err(self.refused(what));
        }
        let ids = self.list("sketch_report_ids", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_report_ids)(self.raw(), n) })?;
        let status = sketch_named(self.api, &SKETCH_STATUSES, sketch_whole(report[0], what)?, what)?;
        Ok(SolveReport { status, iterations: sketch_whole(report[1], what)?, max_residual: report[2], ids })
    }

    /// A new, empty sketch.
    pub fn new() -> Result<Sketch> {
        let api = api()?;
        Sketch::wrap(api, unsafe { (api.cadaclysm_blacksmith_sketch_new)() }, "sketch_new")
    }

    /// A sketch of `profile`'s lines, arcs and curves joined end to end, holes included;
    /// with `infer` the obvious constraints (horizontal, vertical, tangent joints, ...) too.
    /// Ends within `tolerance` count as joined (Python's default is 1e-6).
    pub fn from_profile(profile: &Profile, infer: bool, tolerance: f64) -> Result<Sketch> {
        let api = profile.api;
        let raw = unsafe { (api.cadaclysm_blacksmith_sketch_from_profile)(profile.raw(), infer, tolerance) };
        Sketch::wrap(api, raw, "sketch_from_profile")
    }

    // -- entities

    /// A free point at (`x`, `y`); a coordinate that is not finite is refused.
    pub fn add_point(&self, x: f64, y: f64) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_add_point)(self.raw(), x, y) };
        self.id(got, "sketch_add_point")
    }

    /// A line between the points `a` and `b`.
    pub fn add_line(&self, a: u32, b: u32) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_add_line)(self.raw(), a, b) };
        self.id(got, "sketch_add_line")
    }

    /// A circle of radius `r` about the point `centre`.
    pub fn add_circle(&self, centre: u32, r: f64) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_add_circle)(self.raw(), centre, r) };
        self.id(got, "sketch_add_circle")
    }

    /// A counter-clockwise arc about the point `centre` from the point `start` to the point
    /// `end`.
    pub fn add_arc(&self, centre: u32, start: u32, end: u32) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_add_arc)(self.raw(), centre, start, end) };
        self.id(got, "sketch_add_arc")
    }

    /// A cubic Bezier free curve from the point `start` through the controls `c1` and `c2`
    /// to a new end point at `to`; the curve owns its control points.
    pub fn add_bezier(&self, start: u32, c1: [f64; 2], c2: [f64; 2], to: [f64; 2]) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_add_bezier)(self.raw(), start, c1[0], c1[1], c2[0], c2[1], to[0], to[1]) };
        self.id(got, "sketch_add_bezier")
    }

    /// A rational quadratic (conic) free curve from the point `start` with the control
    /// `control` of `weight` to a new end point at `to`.
    pub fn add_conic(&self, start: u32, control: [f64; 2], to: [f64; 2], weight: f64) -> Result<u32> {
        let got =
            unsafe { (self.api.cadaclysm_blacksmith_sketch_add_conic)(self.raw(), start, control[0], control[1], to[0], to[1], weight) };
        self.id(got, "sketch_add_conic")
    }

    /// A NURBS free curve of `degree` from the point `start` through the control `points`
    /// after it, on `knots`; `weights` `None` for a plain B-spline, or one per control point
    /// counting the start (`points.len() + 1`) -- any other count is refused before the
    /// call. A `u32` degree is never negative.
    pub fn add_nurbs(&self, start: u32, points: &[[f64; 2]], knots: &[f64], degree: u32, weights: Option<&[f64]>) -> Result<u32> {
        let n = points.len();
        // The library reads exactly n + 1 weights whatever the slice holds: check here.
        if let Some(w) = weights {
            if w.len() != n + 1 {
                return Err(Error::new(format!(
                    "sketch_add_nurbs: {} weights for {} control points (the start and {} given); give one per point",
                    w.len(),
                    n + 1,
                    n
                )));
            }
        }
        let got = unsafe {
            (self.api.cadaclysm_blacksmith_sketch_add_nurbs)(
                self.raw(),
                start,
                degree,
                points.as_ptr().cast(),
                n,
                weights.map_or(ptr::null(), <[f64]>::as_ptr),
                knots.as_ptr(),
                knots.len(),
            )
        };
        self.id(got, "sketch_add_nurbs")
    }

    /// The rectangle with opposite corners `a` and `b`: its four corner points,
    /// counter-clockwise from `a`, and its four sides (side `i` from corner `i`).
    pub fn add_rect(&self, a: [f64; 2], b: [f64; 2]) -> Result<([u32; 4], [u32; 4])> {
        let ids = self.list("sketch_add_rect", |n| unsafe {
            (self.api.cadaclysm_blacksmith_sketch_add_rect)(self.raw(), a[0], a[1], b[0], b[1], n)
        })?;
        match <[u32; 8]>::try_from(ids.as_slice()) {
            Ok(all) => Ok(([all[0], all[1], all[2], all[3]], [all[4], all[5], all[6], all[7]])),
            Err(_) => Err(Error::new(format!("sketch_add_rect: the library answered {} ids, not 8", ids.len()))),
        }
    }

    /// The kind of entity `id`: `"point"`, `"line"`, `"circle"`, `"arc"` or `"free_curve"`.
    pub fn kind(&self, id: u32) -> Result<&'static str> {
        let code = unsafe { (self.api.cadaclysm_blacksmith_sketch_kind)(self.raw(), id) };
        sketch_named(self.api, &SKETCH_ENTITY_KINDS, code, "sketch_kind")
    }

    /// The live entity ids, ascending.
    pub fn entities(&self) -> Result<Vec<u32>> {
        self.list("sketch_entities", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_entities)(self.raw(), n) })
    }

    /// The point `id`'s position.
    pub fn point(&self, id: u32) -> Result<[f64; 2]> {
        let mut out = [0.0f64; 2];
        if unsafe { (self.api.cadaclysm_blacksmith_sketch_point)(self.raw(), id, out.as_mut_ptr()) } {
            Ok(out)
        } else {
            Err(fail(self.api, "sketch_point"))
        }
    }

    /// Moves the point `id` to (`x`, `y`) without solving.
    pub fn set_point(&self, id: u32, x: f64, y: f64) -> Result<()> {
        if unsafe { (self.api.cadaclysm_blacksmith_sketch_set_point)(self.raw(), id, x, y) } {
            Ok(())
        } else {
            Err(fail(self.api, "sketch_set_point"))
        }
    }

    /// The radius of the circle or arc `id` (the `"radius"` constraint is
    /// [`radius_of`](Sketch::radius_of)).
    pub fn radius(&self, id: u32) -> Result<f64> {
        let r = unsafe { (self.api.cadaclysm_blacksmith_sketch_radius)(self.raw(), id) };
        if r.is_nan() {
            Err(fail(self.api, "sketch_radius"))
        } else {
            Ok(r)
        }
    }

    /// Sets the circle `id`'s radius to `r` without solving.
    pub fn set_radius(&self, id: u32, r: f64) -> Result<()> {
        if unsafe { (self.api.cadaclysm_blacksmith_sketch_set_radius)(self.raw(), id, r) } {
            Ok(())
        } else {
            Err(fail(self.api, "sketch_set_radius"))
        }
    }

    /// The centre point of the circle or arc `id`.
    pub fn centre(&self, id: u32) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_centre)(self.raw(), id) };
        self.id(got, "sketch_centre")
    }

    /// The points entity `id` runs between: a line's `[a, b]`, an arc's `[start, end]`, a
    /// free curve's `[start, controls..., end]`.
    pub fn ends(&self, id: u32) -> Result<Vec<u32>> {
        self.list("sketch_ends", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_ends)(self.raw(), id, n) })
    }

    /// Marks entity `id` as construction geometry (kept out of profiles) when `on`, or back
    /// when not (Python's default is `true`).
    pub fn set_construction(&self, id: u32, on: bool) -> Result<()> {
        if unsafe { (self.api.cadaclysm_blacksmith_sketch_set_construction)(self.raw(), id, on) } {
            Ok(())
        } else {
            Err(fail(self.api, "sketch_set_construction"))
        }
    }

    /// Whether entity `id` is construction geometry (`false` for an unknown id).
    pub fn is_construction(&self, id: u32) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_sketch_is_construction)(self.raw(), id) }
    }

    /// Whether entity `id` is a reference copy of another sketch's (`false` for an unknown
    /// id).
    pub fn is_reference(&self, id: u32) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_sketch_is_reference)(self.raw(), id) }
    }

    /// Removes entity `id` and the constraints on it, and returns the removed constraint
    /// ids. Refused for a point that lines or circles still use, with the entities holding
    /// it as the error's [`ids`](Error::ids).
    pub fn remove_entity(&self, id: u32) -> Result<Vec<u32>> {
        let mut n = 0usize;
        let p = unsafe { (self.api.cadaclysm_blacksmith_sketch_remove_entity)(self.raw(), id, &mut n) };
        if p.is_null() {
            return Err(self.refused("sketch_remove_entity"));
        }
        self.lent("sketch_remove_entity", p, n)
    }

    /// A fixed construction copy of `other`'s entity `entity`, kept in step by
    /// [`update_reference`](Sketch::update_reference). `other` must be another sketch (the
    /// library refuses `self`, in its own words).
    pub fn reference(&self, other: &Sketch, entity: u32) -> Result<u32> {
        let got = unsafe { (self.api.cadaclysm_blacksmith_sketch_reference)(self.raw(), other.raw(), entity) };
        self.id(got, "sketch_reference")
    }

    /// Refreshes the reference `id` from `other` and re-solves.
    pub fn update_reference(&self, id: u32, other: &Sketch) -> Result<SolveReport> {
        let mut report = [0.0f64; 3];
        let done = unsafe { (self.api.cadaclysm_blacksmith_sketch_update_reference)(self.raw(), id, other.raw(), report.as_mut_ptr()) };
        self.solved(done, &report, "sketch_update_reference")
    }

    // -- constraints: each returns the new constraint's id

    /// Adds a constraint of `kind`; the geometric kinds pass Python's fillers (value 0,
    /// driving true, sense `"auto"`, end `"start"`).
    fn constrain(&self, kind: &str, refs: &[u32], value: f64, driving: bool, sense: &str, end: &str) -> Result<u32> {
        let sense = sketch_code(&SKETCH_SENSES, sense, kind, "sense")?;
        let end = sketch_code(&SKETCH_ENDS, end, kind, "end")?;
        let kind = sketch_code(&SKETCH_CONSTRAINT_KINDS, kind, "sketch_constrain", "kind")?;
        let got = unsafe {
            (self.api.cadaclysm_blacksmith_sketch_constrain)(self.raw(), kind, refs.as_ptr(), refs.len(), value, driving, sense, end)
        };
        if got == NONE {
            return Err(self.refused("sketch_constrain"));
        }
        Ok(got)
    }

    /// The points `a` and `b` at one place. Each constraint method returns the new
    /// constraint's id, and refuses one that conflicts with the sketch, naming the ids it
    /// clashes with in the error's [`ids`](Error::ids).
    pub fn coincident(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("coincident", &[a, b], 0.0, true, "auto", "start")
    }

    /// The point `point` on the line `line`, taken as infinite.
    pub fn point_on_line(&self, point: u32, line: u32) -> Result<u32> {
        self.constrain("point_on_line", &[point, line], 0.0, true, "auto", "start")
    }

    /// The point `point` on the circle `circle`, or on an arc's whole circle.
    pub fn point_on_circle(&self, point: u32, circle: u32) -> Result<u32> {
        self.constrain("point_on_circle", &[point, circle], 0.0, true, "auto", "start")
    }

    /// The points `a` and `b` level with each other (one y).
    pub fn horizontal(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("horizontal", &[a, b], 0.0, true, "auto", "start")
    }

    /// The points `a` and `b` plumb with each other (one x).
    pub fn vertical(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("vertical", &[a, b], 0.0, true, "auto", "start")
    }

    /// The lines `a` and `b` parallel.
    pub fn parallel(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("parallel", &[a, b], 0.0, true, "auto", "start")
    }

    /// The lines `a` and `b` perpendicular.
    pub fn perpendicular(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("perpendicular", &[a, b], 0.0, true, "auto", "start")
    }

    /// The lines `a` and `b` on one line.
    pub fn collinear(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("collinear", &[a, b], 0.0, true, "auto", "start")
    }

    /// The curves `a` and `b` tangent; `sense` is `"auto"`, `"positive"` or `"negative"`.
    pub fn tangent(&self, a: u32, b: u32, sense: &str) -> Result<u32> {
        self.constrain("tangent", &[a, b], 0.0, true, sense, "start")
    }

    /// The free curve `curve` tangent to `other` at its `end` (`"start"` or `"end"`).
    pub fn tangent_at_end(&self, curve: u32, other: u32, end: &str) -> Result<u32> {
        self.constrain("tangent_at_end", &[curve, other], 0.0, true, "auto", end)
    }

    /// The circles or arcs `a` and `b` about one centre.
    pub fn concentric(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("concentric", &[a, b], 0.0, true, "auto", "start")
    }

    /// The lines `a` and `b` of one length.
    pub fn equal_length(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("equal_length", &[a, b], 0.0, true, "auto", "start")
    }

    /// The circles or arcs `a` and `b` of one radius.
    pub fn equal_radius(&self, a: u32, b: u32) -> Result<u32> {
        self.constrain("equal_radius", &[a, b], 0.0, true, "auto", "start")
    }

    /// The point `point` at the middle of the line `line`.
    pub fn midpoint(&self, point: u32, line: u32) -> Result<u32> {
        self.constrain("midpoint", &[point, line], 0.0, true, "auto", "start")
    }

    /// The points `a` and `b` mirrored about the line `about`.
    pub fn symmetric(&self, a: u32, b: u32, about: u32) -> Result<u32> {
        self.constrain("symmetric", &[a, b, about], 0.0, true, "auto", "start")
    }

    /// The entity `entity` held where it is.
    pub fn fix(&self, entity: u32) -> Result<u32> {
        self.constrain("fix", &[entity], 0.0, true, "auto", "start")
    }

    /// The distance between the points `a` and `b`, `value`; a non-`driving` dimension only
    /// reports.
    pub fn distance(&self, a: u32, b: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("distance", &[a, b], value, driving, "auto", "start")
    }

    /// The signed distance from the point `point` to the line `line`, `value`; `sense` is
    /// `"auto"`, `"positive"` (the left of the line) or `"negative"`.
    pub fn point_line_distance(&self, point: u32, line: u32, value: f64, driving: bool, sense: &str) -> Result<u32> {
        self.constrain("point_line_distance", &[point, line], value, driving, sense, "start")
    }

    /// The distance between the parallel lines `a` and `b`, `value`, on `sense`.
    pub fn line_distance(&self, a: u32, b: u32, value: f64, driving: bool, sense: &str) -> Result<u32> {
        self.constrain("line_distance", &[a, b], value, driving, sense, "start")
    }

    /// The distance from the circle `circle` to the line `line`, `value`, on `sense`.
    pub fn circle_line_distance(&self, circle: u32, line: u32, value: f64, driving: bool, sense: &str) -> Result<u32> {
        self.constrain("circle_line_distance", &[circle, line], value, driving, sense, "start")
    }

    /// The distance between the circles `a` and `b`, `value`.
    pub fn circle_distance(&self, a: u32, b: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("circle_distance", &[a, b], value, driving, "auto", "start")
    }

    /// The x distance from the point `a` to the point `b`, `value`.
    pub fn horizontal_distance(&self, a: u32, b: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("horizontal_distance", &[a, b], value, driving, "auto", "start")
    }

    /// The y distance from the point `a` to the point `b`, `value`.
    pub fn vertical_distance(&self, a: u32, b: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("vertical_distance", &[a, b], value, driving, "auto", "start")
    }

    /// The length of the line `line`, `value`.
    pub fn length(&self, line: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("length", &[line], value, driving, "auto", "start")
    }

    /// The angle from the line `a` to the line `b`, `value` radians.
    pub fn angle(&self, a: u32, b: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("angle", &[a, b], value, driving, "auto", "start")
    }

    /// The radius of the circle or arc `circle`, `value`; the constraint's kind is
    /// `"radius"`.
    pub fn radius_of(&self, circle: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("radius", &[circle], value, driving, "auto", "start")
    }

    /// The diameter of the circle or arc `circle`, `value`.
    pub fn diameter(&self, circle: u32, value: f64, driving: bool) -> Result<u32> {
        self.constrain("diameter", &[circle], value, driving, "auto", "start")
    }

    // -- constraint readers

    /// The live constraint ids, ascending.
    pub fn constraints(&self) -> Result<Vec<u32>> {
        self.list("sketch_constraints", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_constraints)(self.raw(), n) })
    }

    /// The kind of constraint `id`, e.g. `"point_line_distance"`.
    pub fn constraint_kind(&self, id: u32) -> Result<&'static str> {
        let code = unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_kind)(self.raw(), id) };
        sketch_named(self.api, &SKETCH_CONSTRAINT_KINDS, code, "sketch_constraint_kind")
    }

    /// The entity ids constraint `id` was made on, in the order given.
    pub fn constraint_refs(&self, id: u32) -> Result<Vec<u32>> {
        self.list("sketch_constraint_refs", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_refs)(self.raw(), id, n) })
    }

    /// The value of the dimension `id`; `None` for a constraint that is not a dimension. An
    /// unknown id is refused.
    pub fn constraint_value(&self, id: u32) -> Result<Option<f64>> {
        let v = unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_value)(self.raw(), id) };
        if v.is_nan() {
            // NaN is both "not a dimension" (no error set) and "no such constraint" (one set).
            return if failed(self.api) { Err(fail(self.api, "sketch_constraint_value")) } else { Ok(None) };
        }
        Ok(Some(v))
    }

    /// Whether the dimension `id` drives the geometry (`false` for a constraint that is not
    /// a dimension). An unknown id is refused.
    pub fn constraint_driving(&self, id: u32) -> Result<bool> {
        let driving = unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_driving)(self.raw(), id) };
        // false is both "not driving" (no error set) and "no such constraint" (one set).
        if !driving && failed(self.api) {
            return Err(fail(self.api, "sketch_constraint_driving"));
        }
        Ok(driving)
    }

    /// The sense of constraint `id`, `"auto"` resolved to the side it took; `"auto"` for a
    /// kind without one.
    pub fn constraint_sense(&self, id: u32) -> Result<&'static str> {
        let code = unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_sense)(self.raw(), id) };
        sketch_named(self.api, &SKETCH_SENSES, code, "sketch_constraint_sense")
    }

    /// The end (`"start"` or `"end"`) of the free curve a
    /// [`tangent_at_end`](Sketch::tangent_at_end) constraint `id` holds; `"start"` for a
    /// kind without one.
    pub fn constraint_end(&self, id: u32) -> Result<&'static str> {
        let code = unsafe { (self.api.cadaclysm_blacksmith_sketch_constraint_end)(self.raw(), id) };
        sketch_named(self.api, &SKETCH_ENDS, code, "sketch_constraint_end")
    }

    /// Whether the tangent constraint `id` joins two curves end to end (`false` otherwise).
    pub fn is_joint_tangent(&self, id: u32) -> bool {
        unsafe { (self.api.cadaclysm_blacksmith_sketch_is_joint_tangent)(self.raw(), id) }
    }

    /// Removes the constraint `id`.
    pub fn remove(&self, id: u32) -> Result<()> {
        if unsafe { (self.api.cadaclysm_blacksmith_sketch_remove)(self.raw(), id) } {
            Ok(())
        } else {
            Err(fail(self.api, "sketch_remove"))
        }
    }

    /// Sets the dimension `id` to `value` and re-solves.
    pub fn set_value(&self, id: u32, value: f64) -> Result<SolveReport> {
        let mut report = [0.0f64; 3];
        let done = unsafe { (self.api.cadaclysm_blacksmith_sketch_set_value)(self.raw(), id, value, report.as_mut_ptr()) };
        self.solved(done, &report, "sketch_set_value")
    }

    /// Makes the dimension `id` drive the geometry (or only report it) and re-solves.
    pub fn set_driving(&self, id: u32, driving: bool) -> Result<SolveReport> {
        let mut report = [0.0f64; 3];
        let done = unsafe { (self.api.cadaclysm_blacksmith_sketch_set_driving)(self.raw(), id, driving, report.as_mut_ptr()) };
        self.solved(done, &report, "sketch_set_driving")
    }

    /// What the geometry measures for the dimension `id` right now.
    pub fn measure(&self, id: u32) -> Result<f64> {
        let v = unsafe { (self.api.cadaclysm_blacksmith_sketch_measure)(self.raw(), id) };
        if v.is_nan() {
            Err(fail(self.api, "sketch_measure"))
        } else {
            Ok(v)
        }
    }

    // -- solving and diagnosis

    /// Solves the sketch. A conflicting or diverged solve is reported, not returned as an
    /// error.
    pub fn solve(&self) -> Result<SolveReport> {
        let mut report = [0.0f64; 3];
        if !unsafe { (self.api.cadaclysm_blacksmith_sketch_solve)(self.raw(), report.as_mut_ptr()) } {
            return Err(fail(self.api, "sketch_solve")); // only a null sketch: no ids to name
        }
        self.solved(true, &report, "sketch_solve")
    }

    /// Drags each point in `moves` (an id and its target) towards its target while the
    /// constraints hold, as a pointer drag does. The moves go to the library in ascending id
    /// order. Refused for an id that is not a point, or one given twice.
    pub fn drag(&self, moves: &[(u32, [f64; 2])]) -> Result<SolveReport> {
        let (points, xy) = sketch_moves(moves)?;
        let mut report = [0.0f64; 3];
        let done = unsafe {
            (self.api.cadaclysm_blacksmith_sketch_drag)(self.raw(), points.as_ptr(), xy.as_ptr(), points.len(), report.as_mut_ptr())
        };
        self.solved(done, &report, "sketch_drag")
    }

    /// The sketch's degrees of freedom, whole and per independent part.
    pub fn diagnose(&self) -> Result<Dof> {
        const WHAT: &str = "sketch_diagnose";
        let mut out = [0.0f64; 3];
        if !unsafe { (self.api.cadaclysm_blacksmith_sketch_diagnose)(self.raw(), out.as_mut_ptr()) } {
            return Err(fail(self.api, WHAT));
        }
        let free = sketch_whole(out[0], WHAT)?;
        let state = sketch_named(self.api, &SKETCH_STATES, sketch_whole(out[1], WHAT)?, WHAT)?;
        let part_count = sketch_whole(out[2], WHAT)?;
        let dof_list = |which: u32| {
            self.list("sketch_dof_list", |n| unsafe { (self.api.cadaclysm_blacksmith_sketch_dof_list)(self.raw(), which, n) })
        };
        let redundant = dof_list(SKETCH_DOF_REDUNDANT)?;
        let conflicting = dof_list(SKETCH_DOF_CONFLICTING)?;
        let free_entities = dof_list(SKETCH_DOF_FREE_ENTITIES)?;
        let mut parts = Vec::new();
        for i in 0..part_count {
            const PART: &str = "sketch_dof_part";
            let mut raw = [0.0f64; 3];
            if !unsafe { (self.api.cadaclysm_blacksmith_sketch_dof_part)(self.raw(), i, raw.as_mut_ptr()) } {
                return Err(fail(self.api, PART));
            }
            let params = sketch_whole(raw[0], PART)?;
            let part_free = sketch_whole(raw[1], PART)?;
            let part_state = sketch_named(self.api, &SKETCH_STATES, sketch_whole(raw[2], PART)?, PART)?;
            let part_list = |which: u32| {
                self.list("sketch_dof_part_list", |n| unsafe {
                    (self.api.cadaclysm_blacksmith_sketch_dof_part_list)(self.raw(), i, which, n)
                })
            };
            parts.push(PartDof {
                params,
                free: part_free,
                state: part_state,
                constraints: part_list(SKETCH_PART_CONSTRAINTS)?,
                redundant: part_list(SKETCH_PART_REDUNDANT)?,
                conflicting: part_list(SKETCH_PART_CONFLICTING)?,
                free_entities: part_list(SKETCH_PART_FREE_ENTITIES)?,
            });
        }
        Ok(Dof { free, state, redundant, conflicting, free_entities, parts })
    }

    /// The closed loops as profiles (nested loops become holes; construction geometry left
    /// out); ends within `tolerance` join (Python's default is 1e-6).
    pub fn profiles(&self, tolerance: f64) -> Result<Vec<Profile>> {
        let list = unsafe { (self.api.cadaclysm_blacksmith_sketch_profiles)(self.raw(), tolerance) };
        profile_list(self.api, list, "sketch_profiles")
    }

    /// The paths that do not close, as profiles; ends within `tolerance` join.
    pub fn open_chains(&self, tolerance: f64) -> Result<Vec<Profile>> {
        let list = unsafe { (self.api.cadaclysm_blacksmith_sketch_open_chains)(self.raw(), tolerance) };
        profile_list(self.api, list, "sketch_open_chains")
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

    /// The placement path of every solid under this assembly, at any depth: depth first,
    /// placements in order, names joined by "/" with a "/" or "\\" inside a name escaped
    /// with "\\" (as [`posed`](Self::posed)'s keys). The index [`swept_clash`](Self::swept_clash)'s
    /// rows use.
    pub fn parts(&self) -> Result<Vec<String>> {
        let count = unsafe { (self.api.cadaclysm_blacksmith_assembly_part_count)(self.raw()) };
        (0..count)
            .map(|i| {
                let raw = unsafe { (self.api.cadaclysm_blacksmith_assembly_part_path)(self.raw(), i) };
                if raw.is_null() {
                    return Err(fail(self.api, "assembly_part_path"));
                }
                let path = unsafe { text(raw) };
                unsafe { (self.api.cadaclysm_blacksmith_string_free)(raw) };
                Ok(path)
            })
            .collect()
    }

    /// Every pair of this assembly's solids (indexed as [`parts`](Self::parts) lists them)
    /// that penetrates, touches or comes within `clearance` of the other anywhere while this
    /// assembly's own mechanism moves through `keyframes`, as [`SweptClash`] rows. Each
    /// keyframe is `(joint, values)` rows, as [`posed`](Self::posed)'s `rows`, and every
    /// keyframe names the same joints (the first fixes their order); time runs in keyframe
    /// units, keyframe `k` at time `k`. Between two keyframes each joint value moves linearly
    /// and each link is posed from those values, so a link swinging about a joint goes round
    /// its arc, not along its chord. Only this assembly's own joints move: a sub-assembly
    /// rides the link its placement is in. `ground` is one of this assembly's links held
    /// fixed (`None` for its default); solids in no link stay still. Pairs on two links a
    /// joint joins are not tested unless `joined`; `allowed` pairs of part indices are never
    /// tested. `tolerance` meshes the parts ([`DEFAULT_TOLERANCE`], 0.05, is Python's
    /// default); `resolution` and `max_steps` are [`Collider::swept_clash`]'s.
    ///
    /// Fails, in the wrapper and before the kernel is called, for a later keyframe naming
    /// other joints than keyframe 0 (`swept_clash: joint 'x' is in keyframe 0 and not in
    /// keyframe 2`), naming a joint twice, or giving a joint another number of values; and
    /// with the kernel's `swept_clash:` words for everything else -- fewer than two
    /// keyframes, an unknown joint or one in a sub-assembly, a wrong value count, a bad
    /// `resolution`, `max_steps` 0, an `allowed` index out of range or an unknown `ground`.
    #[allow(clippy::too_many_arguments)]
    pub fn swept_clash(
        &self,
        keyframes: &[&[(&str, &[f64])]],
        clearance: f64,
        tolerance: f64,
        resolution: f64,
        max_steps: u32,
        allowed: &[(u32, u32)],
        ground: Option<&str>,
        joined: bool,
    ) -> Result<Vec<SweptClash>> {
        // C takes one joint set for every keyframe, values key-major: keyframe 0 fixes the
        // joints, their order and their counts, and a later keyframe that differs is refused
        // here, in the kernel's words, before C is called.
        let first: &[(&str, &[f64])] = keyframes.first().copied().unwrap_or(&[]);
        let mut flat: Vec<f64> = first.iter().flat_map(|(_, v)| v.iter().copied()).collect();
        for (k, row) in keyframes.iter().enumerate().skip(1) {
            let named = |j: &str| row.iter().any(|(n, _)| *n == j);
            let keyed = |j: &str| first.iter().any(|(n, _)| *n == j);
            for (j, _) in first.iter().chain(row.iter()) {
                if !named(j) {
                    return Err(Error::new(format!("swept_clash: joint '{j}' is in keyframe 0 and not in keyframe {k}")));
                }
                if !keyed(j) {
                    return Err(Error::new(format!("swept_clash: joint '{j}' is in keyframe {k} and not in keyframe 0")));
                }
            }
            if let Some((j, _)) = row.iter().enumerate().find_map(|(i, r)| row[..i].iter().any(|(n, _)| *n == r.0).then_some(r)) {
                return Err(Error::new(format!("swept_clash: joint '{j}' is given twice")));
            }
            for (j, want) in first {
                let got = row.iter().find(|(n, _)| n == j).map_or(&[][..], |(_, v)| *v);
                if got.len() != want.len() {
                    return Err(Error::new(format!(
                        "swept_clash: joint '{j}' has {} values in keyframe 0 and {} in keyframe {k}",
                        want.len(),
                        got.len()
                    )));
                }
                flat.extend_from_slice(got);
            }
        }
        let joints: Vec<CString> = first.iter().map(|(j, _)| c_text("joint", j)).collect::<Result<_>>()?;
        let joint_ptrs: Vec<*const c_char> = joints.iter().map(|c| c.as_ptr()).collect();
        let counts: Vec<u32> = first.iter().map(|(_, v)| v.len() as u32).collect();
        let ground_c = ground.map(|g| c_text("ground", g)).transpose()?;
        let allowed_flat: Vec<u32> = allowed.iter().flat_map(|&(a, b)| [a, b]).collect();
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_assembly_swept_clash)(
                self.raw(),
                joint_ptrs.as_ptr(),
                counts.as_ptr(),
                joint_ptrs.len(),
                flat.as_ptr(),
                keyframes.len() as u32,
                ground_c.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
                tolerance,
                clearance,
                resolution,
                max_steps,
                if allowed_flat.is_empty() { ptr::null() } else { allowed_flat.as_ptr() },
                allowed.len() as u32,
                joined,
            )
        };
        swept_clashes_of(self.api, raw, "assembly_swept_clash")
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

    /// This assembly, and everything placed under it, as one Rhino `.3dm`: each distinct
    /// part (as [`Assembly::step_text`] counts them) a block holding its body, each
    /// sub-assembly a block of references to what it places -- nested assemblies are
    /// nested blocks -- and this assembly's own placements references at the top of the
    /// file, on a layer named after it. Each reference is named as its placement was.
    /// `unit` and the warnings as [`rhino3dm_bytes`]. Refused, as `step_text` is, for an
    /// assembly reachable from this one that places nothing.
    pub fn rhino3dm_bytes(&self, unit: Unit) -> Result<Vec<u8>> {
        let mut len = 0usize;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_assembly_3dm_bytes)(self.raw(), unit as u32, &mut len) };
        taken_3dm(self.api, raw, len, "assembly_3dm_bytes")
    }

    /// [`Assembly::rhino3dm_bytes`] written to `path` by the library itself, which names
    /// the file in its refusal when it cannot.
    pub fn write_3dm(&self, path: impl AsRef<FsPath>, unit: Unit) -> Result<()> {
        let path = crate::c_path(path.as_ref())?;
        let ok = unsafe { (self.api.cadaclysm_blacksmith_assembly_3dm)(self.raw(), path.as_ptr(), unit as u32) };
        if !ok {
            return Err(fail(self.api, "assembly_3dm"));
        }
        warn_3dm(self.api);
        Ok(())
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

// ---- documents --------------------------------------------------------------------

/// The owned text a document call returns, read out and freed; null and `last_error` on a
/// refusal.
fn owned_text(api: &'static Api, raw: *mut c_char, what: &str) -> Result<String> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    let out = unsafe { text(raw) };
    unsafe { (api.cadaclysm_blacksmith_string_free)(raw) };
    Ok(out)
}

/// The first id of a changed set's `"added"` list, `{"added": ["n1"], ...}`.
fn first_added(changed: &str) -> Option<String> {
    let rest = &changed[changed.find("\"added\"")? + "\"added\"".len()..];
    let rest = rest.trim_start().strip_prefix(':')?.trim_start().strip_prefix('[')?.trim_start().strip_prefix('"')?;
    let mut id = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(id),
            '\\' => id.push(chars.next()?),
            c => id.push(c),
        }
    }
    None
}

/// A model as data: a graph of nodes (`profile.rect`, `solid.extrude`, `measure.mass`, ...),
/// each a blacksmith verb reading other nodes by id, with named parameters any number can be
/// an `"=expression"` of, evaluated incrementally, and edited by ops that are undoable and
/// branch. Every edit is one commit; the whole thing -- nodes, parameters, history, branches
/// -- saves as JSON text and loads back to the same document. [`Document::kinds`] lists the
/// node kinds.
///
/// ```no_run
/// use cadaclysm_sdk::blacksmith::{Document, Solid};
///
/// fn main() -> cadaclysm_sdk::Result<()> {
///     let mut doc = Document::new("mm")?;
///     let held = doc.add_solid(&Solid::cuboid(10.0, 10.0, 10.0)?.coloured("#d33", None)?, false)?;
///     let text = doc.save()?;
///
///     let mut doc = Document::load(&text)?;
///     assert_eq!(doc.result_kind(&held)?, "solid");
///     let solid = doc.result_solid(&held)?; // an ordinary Solid, freed when dropped
///     println!("{} faces, {:?}", solid.faces()?, solid.face_colour(0)?);
///     Ok(())
/// }
/// ```
///
/// A refused op is an [`Error`] with the reason, and the document is unchanged. Ops, the
/// changed sets, the statuses, `errors` and `value` are JSON text, as the C ABI has them:
/// this crate reads no JSON. `result_*`, `value`, `errors` and `evaluate` bring the nodes up
/// to date first, so the answer is always the current document's; each [`Solid`] and
/// [`Profile`] a result gives is the caller's own, outlives later edits and the document,
/// and draws, meshes and answers like any other. Dropping the document frees it. `Send`,
/// not `Sync`: one thread at a time.
pub struct Document {
    handle: NonNull<sys::CadaclysmBlacksmithDocument>,
    api: &'static Api,
}

// The document owns its nodes and cache outright, so it may move to another thread; the
// kernel's document is a mutable object for one thread at a time, so it is not `Sync`.
unsafe impl Send for Document {}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_blacksmith_document_free)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Document {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Document({:p})", self.handle)
    }
}

impl Document {
    fn wrap(api: &'static Api, raw: *mut sys::CadaclysmBlacksmithDocument, what: &str) -> Result<Document> {
        NonNull::new(raw).map(|handle| Document { handle, api }).ok_or_else(|| fail(api, what))
    }

    fn raw(&self) -> *mut sys::CadaclysmBlacksmithDocument {
        self.handle.as_ptr()
    }

    /// An empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`).
    pub fn new(units: &str) -> Result<Document> {
        let api = api()?;
        let units = c_text("units", units)?;
        Document::wrap(api, unsafe { (api.cadaclysm_blacksmith_document_new)(units.as_ptr()) }, "document_new")
    }

    /// The document [`Document::save`] wrote as `text`: its nodes, parameters, history and
    /// branches. An error for text that is not a document.
    pub fn load(text: &str) -> Result<Document> {
        let api = api()?;
        let text = c_text("document", text)?;
        Document::wrap(api, unsafe { (api.cadaclysm_blacksmith_document_load)(text.as_ptr()) }, "document_load")
    }

    /// The document saved in the file `path`.
    pub fn open(path: impl AsRef<FsPath>) -> Result<Document> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path).map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
        Document::load(&text)
    }

    /// Every node kind the library knows, as a JSON array of rows (`name`, `inputs`,
    /// `output`, `cost`, `help`). Needs no document.
    pub fn kinds() -> Result<String> {
        let api = api()?;
        owned_text(api, unsafe { (api.cadaclysm_blacksmith_document_kinds)() }, "document_kinds")
    }

    // -- building documents

    /// An empty building document: the blacksmith kinds and the `bim.*` ones, with a hidden
    /// `bim.project` node (one commit) whose random guid seeds every IFC GlobalId it exports
    /// ([`Document::export_ifc`]).
    pub fn new_bim(units: &str) -> Result<Document> {
        let api = api()?;
        let units = c_text("units", units)?;
        Document::wrap(api, unsafe { (api.cadaclysm_bim_document_new)(units.as_ptr()) }, "bim_document_new")
    }

    /// A saved building document, opened with the `bim.*` kinds.
    pub fn load_bim(text: &str) -> Result<Document> {
        let api = api()?;
        let text = c_text("document", text)?;
        Document::wrap(api, unsafe { (api.cadaclysm_bim_document_load)(text.as_ptr()) }, "bim_document_load")
    }

    /// The building document saved in the file `path`.
    pub fn open_bim(path: impl AsRef<FsPath>) -> Result<Document> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path).map_err(|e| Error::new(format!("{}: {e}", path.display())))?;
        Document::load_bim(&text)
    }

    /// Every node kind a building document knows, the blacksmith's and the `bim.*` ones, as
    /// [`Document::kinds`] lists them. Needs no document.
    pub fn bim_kinds() -> Result<String> {
        let api = api()?;
        owned_text(api, unsafe { (api.cadaclysm_bim_kinds)() }, "bim_kinds")
    }

    /// The building as IFC text; write it to a file yourself. `options` is JSON text,
    /// `{"schema": "IFC4"|"IFC2X3", "geometry": "parametric"|"exact", "timestamp": <Unix
    /// seconds>, "name": <IfcProject name>}`, every key optional; `None` is every default
    /// (IFC4, parametric, now, no name). An error for a document not opened as a building
    /// document ([`Document::new_bim`], [`Document::load_bim`]), for bad options, and for a
    /// refused export, whose text is the C ABI's verbatim:
    /// `bim_document_export_ifc: {"refusals": [{"node": <id>|null, "reason": <text>}]}`.
    pub fn export_ifc(&mut self, options: Option<&str>) -> Result<String> {
        let options = options.filter(|o| !o.is_empty()).map(|o| c_text("options", o)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_bim_document_export_ifc)(self.raw(), options.as_ref().map_or(ptr::null(), |o| o.as_ptr()))
        };
        owned_text(self.api, raw, "bim_document_export_ifc")
    }

    /// Free it now rather than at the end of scope.
    pub fn close(self) {}

    // -- saving

    /// The document as JSON text.
    pub fn save(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_save)(self.raw()) }, "document_save")
    }

    // -- editing

    /// Applies one op, as JSON text (`{"op": "add", "node": {...}}`, `set`, `remove`,
    /// `rename`, `param`), and records it as one commit with `message`. The changed set,
    /// `{"added": [ids], "changed": [ids], "removed": [ids], "params": [names]}`.
    pub fn apply(&mut self, op: &str, message: Option<&str>) -> Result<String> {
        let op = c_text("op", op)?;
        let message = message.filter(|m| !m.is_empty()).map(|m| c_text("message", m)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_document_apply)(self.raw(), op.as_ptr(), message.as_ref().map_or(ptr::null(), |m| m.as_ptr()))
        };
        owned_text(self.api, raw, "document_apply")
    }

    /// A node holding `solid` exactly as it is -- one made in code or read from a file -- for
    /// other nodes to read like any built one: a `solid.body` (a `sheet.body` with `sheet`)
    /// carrying the kernel's own B-rep ([`Solid::document_body`]), in this document's units.
    /// Fillets and other references are taken off it as off any node. Its id is returned. Its
    /// colours are kept -- the solid's, each face's and each edge's -- its name is not.
    pub fn add_solid(&mut self, solid: &Solid, sheet: bool) -> Result<String> {
        let kind = if sheet { "sheet.body" } else { "solid.body" };
        let body = solid.document_body()?;
        self.add_holding(&format!(r#"{{"op": "add", "node": {{"kind": "{kind}", "body": {body}}}}}"#))
    }

    /// A `profile.path` node holding `profile` exactly ([`Profile::document_path`]: arcs and
    /// NURBS as they are, holes included, its colour kept), in this document's units. Its id
    /// is returned.
    pub fn add_profile(&mut self, profile: &Profile) -> Result<String> {
        let path = profile.document_path()?;
        self.add_holding(&format!(r#"{{"op": "add", "node": {{"kind": "profile.path", "path": {path}}}}}"#))
    }

    fn add_holding(&mut self, op: &str) -> Result<String> {
        let changed = self.apply(op, None)?;
        first_added(&changed).ok_or_else(|| Error::new(format!("document_apply: no node was added ({changed})")))
    }

    /// Runs `body` as one batch: the ops it applies are live inside it and recorded as one
    /// commit with `message` when it returns `Ok` (nothing at all when it applied none). When
    /// it returns `Err` -- or panics -- every op of the batch is taken back and the body's
    /// own error (or panic) is passed on, never a refused clean-up's. An error, before the
    /// body runs, while a batch or a preview is already open (`document_batch_begin: ...`).
    pub fn batch<T, E, F>(&mut self, message: Option<&str>, body: F) -> std::result::Result<T, E>
    where
        F: FnOnce(&mut Document) -> std::result::Result<T, E>,
        E: From<Error>,
    {
        let message = message.filter(|m| !m.is_empty()).map(|m| c_text("message", m)).transpose()?;
        let begun = unsafe {
            (self.api.cadaclysm_blacksmith_document_batch_begin)(self.raw(), message.as_ref().map_or(ptr::null(), |m| m.as_ptr()))
        };
        if !begun {
            return Err(fail(self.api, "document_batch_begin").into());
        }
        let abort = |doc: &mut Document| {
            // The body's own error is the one to report, not a failed clean-up.
            let _ = owned_text(doc.api, unsafe { (doc.api.cadaclysm_blacksmith_document_batch_abort)(doc.raw()) }, "document_batch_abort");
        };
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| body(self))) {
            Ok(Ok(out)) => {
                owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_batch_end)(self.raw()) }, "document_batch_end")?;
                Ok(out)
            }
            Ok(Err(e)) => {
                abort(self);
                Err(e)
            }
            Err(panic) => {
                abort(self);
                std::panic::resume_unwind(panic)
            }
        }
    }

    /// Runs `body` as a preview -- a what-if: the ops it applies are applied (and evaluate)
    /// but never recorded, and are taken back when it returns, `Ok` or `Err`, or panics. The
    /// body's own error (or panic) is passed on, never a refused clean-up's. An error, before
    /// the body runs, while a batch or a preview is already open (`document_preview_begin: ...`).
    /// For an editor's drag, see [`Document::preview_frame`].
    pub fn preview<T, E, F>(&mut self, body: F) -> std::result::Result<T, E>
    where
        F: FnOnce(&mut Document) -> std::result::Result<T, E>,
        E: From<Error>,
    {
        if !unsafe { (self.api.cadaclysm_blacksmith_document_preview_begin)(self.raw()) } {
            return Err(fail(self.api, "document_preview_begin").into());
        }
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| body(self))) {
            Ok(Ok(out)) => {
                self.end_preview()?;
                Ok(out)
            }
            Ok(Err(e)) => {
                // The body's own error is the one to report, not a failed clean-up.
                let _ = self.end_preview();
                Err(e)
            }
            Err(panic) => {
                let _ = self.end_preview();
                std::panic::resume_unwind(panic)
            }
        }
    }

    /// One frame of an editor's drag: applies `op` (JSON text, as [`Document::apply`])
    /// without recording it, after taking back the last frame -- each frame replaces the one
    /// before, relative to the state before the drag. The changed set, relative to that state.
    /// Needs no [`Document::preview`] scope; [`Document::end_preview`] ends the drag.
    pub fn preview_frame(&mut self, op: &str) -> Result<String> {
        let op = c_text("op", op)?;
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_preview)(self.raw(), op.as_ptr()) }, "document_preview")
    }

    /// Takes back the open preview -- an editor's drag ([`Document::preview_frame`]) -- leaving
    /// the document as it was before it; the changed set of doing so.
    pub fn end_preview(&mut self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_end_preview)(self.raw()) }, "document_end_preview")
    }

    // -- history

    /// Takes back the head commit. False when there was nothing to take back.
    pub fn undo(&mut self) -> Result<bool> {
        let text = owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_undo)(self.raw()) }, "document_undo")?;
        Ok(text.trim() != "null")
    }

    /// Puts back the commit [`Document::undo`] took back. False when there was nothing to put back.
    pub fn redo(&mut self) -> Result<bool> {
        let text = owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_redo)(self.raw()) }, "document_redo")?;
        Ok(text.trim() != "null")
    }

    /// The parameters as a JSON object, name to value (a number, or an `"=expression"`).
    /// Set one with a `param` op ([`Document::apply`]).
    pub fn params(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_params)(self.raw()) }, "document_params")
    }

    // -- branches

    /// The branches as JSON, `{"branches": {name: tip commit id}, "branch": name|null (null:
    /// the head is detached), "head": commit id, "unnamed": [commit ids], "can_undo": bool,
    /// "can_redo": bool}`.
    pub fn branches(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_branch_list)(self.raw()) }, "document_branch_list")
    }

    /// A new branch `name`. With `at` `None` it starts at the head and the document switches
    /// onto it; with `at` (a commit id) it starts there and the head stays where it is.
    pub fn branch_new(&mut self, name: &str, at: Option<&str>) -> Result<()> {
        let name = c_text("branch name", name)?;
        let at = at.filter(|a| !a.is_empty()).map(|a| c_text("commit id", a)).transpose()?;
        let raw = unsafe {
            (self.api.cadaclysm_blacksmith_document_branch_new)(self.raw(), name.as_ptr(), at.as_ref().map_or(ptr::null(), |a| a.as_ptr()))
        };
        owned_text(self.api, raw, "document_branch_new").map(drop)
    }

    /// Moves the head to the branch of that name, else to the commit of that id (which
    /// detaches the head: `"branch"` is then null in [`Document::branches`]). The nodes follow.
    pub fn switch(&mut self, name_or_commit_id: &str) -> Result<()> {
        let to = c_text("branch or commit", name_or_commit_id)?;
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_branch_switch)(self.raw(), to.as_ptr()) }, "document_branch_switch")
            .map(drop)
    }

    /// Renames branch `old` to `new`; an error when `old` is missing or `new` is taken.
    pub fn branch_rename(&mut self, old: &str, new: &str) -> Result<()> {
        let (old, new) = (c_text("branch name", old)?, c_text("branch name", new)?);
        if !unsafe { (self.api.cadaclysm_blacksmith_document_branch_rename)(self.raw(), old.as_ptr(), new.as_ptr()) } {
            return Err(fail(self.api, "document_branch_rename"));
        }
        Ok(())
    }

    /// Deletes branch `name`; the current branch is refused. Its commits stay, as tips.
    pub fn branch_delete(&mut self, name: &str) -> Result<()> {
        let name = c_text("branch name", name)?;
        if !unsafe { (self.api.cadaclysm_blacksmith_document_branch_delete)(self.raw(), name.as_ptr()) } {
            return Err(fail(self.api, "document_branch_delete"));
        }
        Ok(())
    }

    /// The tips of the lines no branch names -- what an undo followed by an edit leaves
    /// behind -- as JSON, each a whole commit as [`Document::log`] writes it.
    pub fn tips(&self) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_tips)(self.raw()) }, "document_tips")
    }

    /// The commits of `branch`'s line, newest first, the root `c0` last, as JSON,
    /// `[{"id", "parents", "message"?, "author"?, "time"?, "ops"}]`; `None` is the line from
    /// the head back to the root (its first commit is the head). An error for a branch that
    /// does not exist.
    pub fn log(&self, branch: Option<&str>) -> Result<String> {
        let branch = branch.filter(|b| !b.is_empty()).map(|b| c_text("branch name", b)).transpose()?;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_document_log)(self.raw(), branch.as_ref().map_or(ptr::null(), |b| b.as_ptr())) };
        owned_text(self.api, raw, "document_log")
    }

    // -- evaluating and reading back

    /// Evaluates the nodes that are stale (only the cheap kinds with `cheap_only`); the status
    /// of every node as JSON, `[{"id", "state": "ok"|"error"|"blocked"|"pending", ...}]`.
    pub fn evaluate(&mut self, cheap_only: bool) -> Result<String> {
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_evaluate)(self.raw(), cheap_only) }, "document_evaluate")
    }

    fn up_to_date(&mut self) -> Result<()> {
        self.evaluate(false).map(drop)
    }

    fn id(id: &str) -> Result<CString> {
        c_text("node id", id)
    }

    /// The nodes the evaluation left in error or blocked, as JSON, `[{"id", "state", "message"}]`.
    pub fn errors(&mut self) -> Result<String> {
        self.up_to_date()?;
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_errors)(self.raw()) }, "document_errors")
    }

    /// Node `id`'s value as JSON: a number, a point or list, a record, text. An error for a
    /// node with none (missing, or in error).
    pub fn value(&mut self, id: &str) -> Result<String> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_value)(self.raw(), key.as_ptr()) }, "document_value")
    }

    /// What node `id` evaluated to: `"solid"`, `"sheet"`, `"profile"`, `"profiles"` (a list
    /// of profiles, or a sketch's outlines), `"nurbs"`, `"subd"`, `"curve"`, `"list"` (a node
    /// run over a list: its items are `id#0`, `id#1`, ...), `"value"`, or `"none"` (no such
    /// node, or one that failed). Read a solid or sheet with [`Document::result_solid`], a
    /// profile with [`Document::result_profile`], profiles with
    /// [`Document::result_profiles`], a NURBS curve with [`Document::result_nurbs_curve`], a
    /// cage with [`Document::result_subd`], anything else with [`Document::value`].
    pub fn result_kind(&mut self, id: &str) -> Result<String> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        owned_text(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_result_kind)(self.raw(), key.as_ptr()) }, "document_result_kind")
    }

    /// Node `id`'s solid or sheet, as a [`Solid`] of the caller's own. An error when `id` is
    /// not an evaluated solid or sheet: no such node, one that failed, or another kind.
    pub fn result_solid(&mut self, id: &str) -> Result<Solid> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        Solid::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_result_solid)(self.raw(), key.as_ptr()) }, "document_result_solid")
    }

    /// Node `id`'s profile, as a [`Profile`] of the caller's own. An error when `id` is not an
    /// evaluated profile.
    pub fn result_profile(&mut self, id: &str) -> Result<Profile> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        Profile::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_result_profile)(self.raw(), key.as_ptr()) }, "document_result_profile")
    }

    /// Node `id`'s profiles, when it is a list of profiles (or a sketch), each a [`Profile`] of
    /// the caller's own. An error otherwise.
    pub fn result_profiles(&mut self, id: &str) -> Result<Vec<Profile>> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        let count = unsafe { (self.api.cadaclysm_blacksmith_document_result_profile_count)(self.raw(), key.as_ptr()) };
        if count == NONE {
            return Err(fail(self.api, "document_result_profile_count"));
        }
        (0..count)
            .map(|i| {
                let raw = unsafe { (self.api.cadaclysm_blacksmith_document_result_profile_at)(self.raw(), key.as_ptr(), i) };
                Profile::wrap(self.api, raw, "document_result_profile_at")
            })
            .collect()
    }

    /// Node `id`'s NURBS curve (kind `"nurbs"`), as a [`NurbsCurve`] of the caller's own. An
    /// error otherwise. (A plane curve, kind `"curve"`, has no handle: read its [`Document::value`].)
    pub fn result_nurbs_curve(&mut self, id: &str) -> Result<NurbsCurve> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        let raw = unsafe { (self.api.cadaclysm_blacksmith_document_result_nurbs_curve)(self.raw(), key.as_ptr()) };
        NurbsCurve::wrap(self.api, raw, "document_result_nurbs_curve")
    }

    /// Node `id`'s subdivision cage (kind `"subd"`), as a [`Subd`] of the caller's own. An
    /// error otherwise.
    pub fn result_subd(&mut self, id: &str) -> Result<Subd> {
        self.up_to_date()?;
        let key = Document::id(id)?;
        Subd::wrap(self.api, unsafe { (self.api.cadaclysm_blacksmith_document_result_subd)(self.raw(), key.as_ptr()) }, "document_result_subd")
    }
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

// ---- Rhino 3dm --------------------------------------------------------------------

/// Several solids as one Rhino `.3dm` (version 8, which Rhino 8 and 9 open), one object
/// each: its exact brep, or -- where a body has no exact form there -- its mesh, with a
/// warning saying so. Each object is named as its solid is, coloured with the solid's own
/// colour (a face's or an edge's own is left out) and carries the solid's attributes as
/// user text. `unit` is the file's: the numbers written are the numbers held. The
/// warnings -- one a line of what was not written as itself -- go to standard error, each
/// starting "3dm: ".
pub fn rhino3dm_bytes(solids: &[&Solid], unit: Unit) -> Result<Vec<u8>> {
    let api = api()?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let mut len = 0usize;
    let raw = unsafe { (api.cadaclysm_blacksmith_3dm_bytes)(handles.as_ptr(), handles.len(), unit as u32, &mut len) };
    taken_3dm(api, raw, len, "3dm_bytes")
}

/// [`rhino3dm_bytes`] written to `path` by the library itself, which names the file in
/// its refusal when it cannot.
pub fn write_3dm(path: impl AsRef<FsPath>, solids: &[&Solid], unit: Unit) -> Result<()> {
    let api = api()?;
    let path = crate::c_path(path.as_ref())?;
    let handles: Vec<_> = solids.iter().map(|s| s.raw()).collect();
    let ok = unsafe { (api.cadaclysm_blacksmith_3dm)(handles.as_ptr(), handles.len(), path.as_ptr(), unit as u32) };
    if !ok {
        return Err(fail(api, "3dm"));
    }
    warn_3dm(api);
    Ok(())
}

/// What a `.3dm` write did not write as itself -- `last_error` on a success, a line
/// each -- said on standard error, one line each.
fn warn_3dm(api: &Api) {
    let notes = unsafe { text((api.cadaclysm_blacksmith_last_error)()) };
    for line in notes.split('\n').filter(|l| !l.is_empty()) {
        eprintln!("3dm: {line}");
    }
}

/// The bytes a `.3dm` call handed over, copied out and released with `bytes_free`
/// (never `string_free`), its notes warned; null is the failure `last_error` names.
fn taken_3dm(api: &Api, raw: *mut u8, len: usize, what: &str) -> Result<Vec<u8>> {
    if raw.is_null() {
        return Err(fail(api, what));
    }
    warn_3dm(api);
    let bytes = unsafe { std::slice::from_raw_parts(raw, len) }.to_vec();
    unsafe { (api.cadaclysm_blacksmith_bytes_free)(raw, len) };
    Ok(bytes)
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
    fn subdivide_whole_one_face_and_a_bad_face() {
        if !kernel_present() {
            return;
        }
        let cage = Subd::cuboid([2.0, 2.0, 2.0], [2, 2, 2]).unwrap();
        assert_eq!(cage.subdivide(&[]).unwrap().faces().unwrap().len(), 96);
        let one = cage.subdivide(&[1]).unwrap();
        assert_eq!(one.faces().unwrap().len(), 27);
        match one.selection().unwrap() {
            Some(SubdSelection::Faces(ids)) => assert_eq!(ids.len(), 4),
            other => panic!("expected 4 selected faces, got {other:?}"),
        }
        let message = refused(cage.subdivide(&[999]));
        assert!(message.contains("subdivide: face 999 is not in the cage"), "{message}");
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
        // Zero rings is legal (a partial overlap of curved faces whose outlines cross); the header's sizes.
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

    /// A material and an outside style read back, ride a move and a cut (the target's
    /// win), reach STEP, and are refused when they name nothing.
    #[test]
    fn a_material_and_an_outside_style_read_back_and_reach_step() {
        let cube = match Solid::cuboid(1.0, 1.0, 1.0) {
            Ok(cube) => cube,
            Err(err) => {
                eprintln!("skipped: {err} (no kernel library)");
                return;
            }
        };
        assert_eq!((cube.material(), cube.style_location(), cube.style_identification()), (None, None, None));
        let steel = cube
            .with_material("Steel")
            .and_then(|s| s.styled(Some("materials/steel.mtlx"), Some("BrushedSteel")))
            .expect("steel");
        assert_eq!(steel.material().as_deref(), Some("Steel"));
        assert_eq!(steel.style_location().as_deref(), Some("materials/steel.mtlx"));
        assert_eq!(steel.style_identification().as_deref(), Some("BrushedSteel"));
        let tool = cube.with_material("Oak").and_then(|s| s.translate(0.5, 0.5, 0.5)).expect("tool");
        let cut = steel.translate(1.0, 0.0, 0.0).and_then(|s| s.cut(&tool.translate(1.0, 0.0, 0.0).expect("moved"), 0.05)).expect("cut");
        assert_eq!(cut.material().as_deref(), Some("Steel"));
        assert_eq!(cut.style_identification().as_deref(), Some("BrushedSteel"));
        let text = steel.step_text(None, Unit::Millimetre).expect("step");
        assert!(text.contains("MATERIAL_DESIGNATION('Steel'"), "{text}");
        assert!(text.contains("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')"), "{text}");
        assert!(cube.with_material(" ").is_err(), "a blank material was accepted");
        assert!(cube.styled(None, None).is_err(), "a style naming nothing was accepted");
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

    // ---- an assembly's swept clash (swept clash plan 3c) --------------------------------
    // Python's `_rig`: a `base` plate on link `ground`; an `arm`, cuboid(3, 0.2, 0.2) from the
    // hinge out along x, on link `arm`, turning on `hinge` (revolute about z through the
    // origin); a `carriage` far out on `slide` (cylindrical, two values); and two cubes in no
    // link, held fixed: `chord` below the hinge, which the chord between the arm's end poses
    // crosses and its arc never does, and `circle` on the arm's circle at 90 degrees.

    /// One keyframe: `(joint, values)` rows, as [`Assembly::posed`] takes them.
    type Keyframe<'a> = &'a [(&'a str, &'a [f64])];

    fn rig(hand: Option<&Assembly>) -> Assembly {
        let rig = Assembly::new("rig").unwrap();
        rig.place_solid(&Solid::cuboid(1.0, 1.0, 0.4).unwrap(), &at(0.0, 0.0, -1.0), Some("base")).unwrap();
        match hand {
            None => rig.place_solid(&Solid::cuboid(3.0, 0.2, 0.2).unwrap(), &at(1.5, 0.0, 0.0), Some("arm")).unwrap(),
            Some(hand) => rig.place_assembly(hand, &at(1.5, 0.0, 0.0), Some("hand")).unwrap(),
        };
        let cube = Solid::cuboid(0.4, 0.4, 0.4).unwrap();
        rig.place_solid(&cube, &at(0.0, -1.2, 0.0), Some("chord")).unwrap();
        rig.place_solid(&cube, &at(0.0, 1.5, 0.0), Some("circle")).unwrap();
        rig.place_solid(&cube, &at(20.0, 0.0, 0.0), Some("carriage")).unwrap();
        rig.link("ground", &["base"]).unwrap();
        rig.link("arm", &[if hand.is_none() { "arm" } else { "hand" }]).unwrap();
        rig.link("carriage", &["carriage"]).unwrap();
        for (joint, end, kind) in [("hinge", "arm", "revolute"), ("slide", "carriage", "cylindrical")] {
            rig.joint(joint, "ground", end).unwrap();
            rig.pair(joint, kind, &at(0.0, 0.0, 0.0), &PairOptions::default()).unwrap();
        }
        rig.base("ground").unwrap();
        rig
    }

    /// A `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`.
    fn hand() -> Assembly {
        let hand = Assembly::new("hand").unwrap();
        hand.place_solid(&Solid::cuboid(0.4, 0.4, 0.4).unwrap(), &at(0.0, 0.0, 0.0), Some("tip")).unwrap();
        hand.place_solid(&Solid::cuboid(0.2, 0.2, 0.2).unwrap(), &at(0.0, 0.0, 2.0), Some("nub")).unwrap();
        hand.link("body", &["tip"]).unwrap();
        hand.link("nubs", &["nub"]).unwrap();
        hand.joint("turn", "body", "nubs").unwrap();
        hand.pair("turn", "revolute", &at(0.0, 0.0, 0.0), &PairOptions::default()).unwrap();
        hand
    }

    /// The hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned.
    const SWING: [Keyframe<'static>; 3] = [
        &[("hinge", &[0.0]), ("slide", &[0.0, 0.0])],
        &[("hinge", &[std::f64::consts::FRAC_PI_2]), ("slide", &[0.5, 0.0])],
        &[("hinge", &[std::f64::consts::PI]), ("slide", &[1.0, 0.0])],
    ];

    /// The time the arm's leading face (y = 0.1 in its own frame) is `gap` from the circle
    /// cube's corner (0.2, 1.3), the first point it meets, in the first segment.
    fn circle_time(gap: f64) -> f64 {
        let (r, phi) = (1.3f64.hypot(0.2), 0.2f64.atan2(1.3));
        (((0.1 + gap) / r).acos() - phi) / std::f64::consts::FRAC_PI_2
    }

    /// `rig`'s sweep with every other argument at Python's defaults, `tolerance` at `SWEPT_TOL`.
    fn sweep(rig: &Assembly, keyframes: &[Keyframe]) -> Result<Vec<SweptClash>> {
        rig.swept_clash(keyframes, 0.0, SWEPT_TOL, 1e-3, 100_000, &[], None, false)
    }

    fn names_of(names: &[String], rows: &[SweptClash]) -> Vec<(String, String)> {
        rows.iter().map(|r| (names[r.a as usize].clone(), names[r.b as usize].clone())).collect()
    }

    #[test]
    fn assembly_parts_are_listed_depth_first_and_escaped() {
        if !kernel_present() {
            return;
        }
        let sub = Assembly::new("pair").unwrap();
        sub.place_solid(&Solid::cuboid(1.0, 1.0, 1.0).unwrap(), &at(0.0, 0.0, 0.0), Some("x")).unwrap();
        sub.place_solid(&Solid::cuboid(1.0, 1.0, 1.0).unwrap(), &at(2.0, 0.0, 0.0), Some("y")).unwrap();
        let top = Assembly::new("top").unwrap();
        top.place_solid(&Solid::cuboid(1.0, 1.0, 1.0).unwrap(), &at(0.0, 5.0, 0.0), Some("p")).unwrap();
        top.place_assembly(&sub, &at(0.0, 0.0, 0.0), Some("a/b")).unwrap();
        top.place_solid(&Solid::cuboid(1.0, 1.0, 1.0).unwrap(), &at(0.0, 9.0, 0.0), Some("q")).unwrap();
        assert_eq!(top.parts().unwrap(), ["p", "a\\/b/x", "a\\/b/y", "q"]);
        assert!(Assembly::new("empty").unwrap().parts().unwrap().is_empty());
    }

    /// Catches the values flattened joint-major (the hinge would read the carriage's values
    /// and never reach the circle cube), the chord swept, and rows that do not index `parts()`.
    #[test]
    fn assembly_swept_clash_sweeps_the_arc_not_the_chord() {
        if !kernel_present() {
            return;
        }
        let rig = rig(None);
        let names = rig.parts().unwrap();
        assert_eq!(names, ["base", "arm", "chord", "circle", "carriage"]);
        let rows = sweep(&rig, &SWING).unwrap();
        assert_eq!(names_of(&names, &rows), [("arm".to_string(), "circle".to_string())], "{rows:?}");
        let r = &rows[0];
        let first: &Clash = &r.first;
        assert_eq!((first.a, first.b), (r.a, r.b));
        let (within, meets) = (circle_time(SWEPT_TOL), circle_time(0.0));
        assert!(within - 1e-9 <= r.first_time && r.first_time <= meets + 1e-9, "{} not in [{within}, {meets}]", r.first_time);
    }

    /// The arm starts at 1.5 rad, already through the circle cube: penetrating at time 0, and
    /// the overlap rebuilt from the first row lies inside the arm's box turned 1.5 about z.
    #[test]
    fn assembly_swept_clash_first_is_at_the_posed_frames() {
        if !kernel_present() {
            return;
        }
        let rig = rig(None);
        let pi = std::f64::consts::PI;
        let rows = sweep(&rig, &[&[("hinge", &[1.5]), ("slide", &[0.0, 0.0])], &[("hinge", &[pi]), ("slide", &[0.0, 0.0])]]).unwrap();
        assert_eq!(rows.iter().map(|r| (r.a, r.b, r.first_time)).collect::<Vec<_>>(), [(1, 3, 0.0)], "{rows:?}");
        let got = rows[0].first.solid().unwrap().bounds_box(SWEPT_TOL).unwrap();
        let (co, si) = (1.5f64.cos(), 1.5f64.sin());
        let turned = Frame::new([0.0; 3], [co, si, 0.0], [-si, co, 0.0], [0.0, 0.0, 1.0]).unwrap();
        let want = Solid::cuboid(3.0, 0.2, 0.2).unwrap().translate(1.5, 0.0, 0.0).unwrap().bounds_box(SWEPT_TOL).unwrap().moved(&turned).unwrap();
        for k in 0..3 {
            assert!(want.lo[k] - 1e-6 <= got.lo[k] && got.hi[k] <= want.hi[k] + 1e-6, "{got:?} not inside {want:?}");
        }
        assert!(got.lo[1] >= 1.3 - 4.0 * SWEPT_TOL && got.hi[1] <= 1.7 + 4.0 * SWEPT_TOL && got.hi[0] > got.lo[0], "{got:?}");
    }

    /// A pin on the arm's link inside a bore on the ground link, the hinge joining them;
    /// catches `joined` dropped on its way to the kernel.
    #[test]
    fn assembly_swept_clash_tests_joined_links_only_when_asked() {
        if !kernel_present() {
            return;
        }
        let pinned = Assembly::new("pinned").unwrap();
        pinned.place_solid(&Solid::cuboid(0.6, 0.6, 0.6).unwrap(), &at(0.0, 0.0, 0.0), Some("bore")).unwrap();
        pinned.place_solid(&Solid::cuboid(0.2, 0.2, 0.2).unwrap(), &at(0.0, 0.0, 0.0), Some("pin")).unwrap();
        pinned.link("ground", &["bore"]).unwrap();
        pinned.link("arm", &["pin"]).unwrap();
        pinned.joint("hinge", "ground", "arm").unwrap();
        pinned.pair("hinge", "revolute", &at(0.0, 0.0, 0.0), &PairOptions::default()).unwrap();
        let keys: [Keyframe; 2] = [&[("hinge", &[0.0])], &[("hinge", &[1.0])]];
        let sweep = |joined: bool, allowed: &[(u32, u32)]| {
            let rows = pinned.swept_clash(&keys, 0.0, SWEPT_TOL, 1e-3, 100_000, allowed, None, joined).unwrap();
            rows.iter().map(|r| (r.a, r.b, r.first_time)).collect::<Vec<_>>()
        };
        assert_eq!(sweep(false, &[]), []);
        assert_eq!(sweep(true, &[]), [(0, 1, 0.0)]);
        assert_eq!(sweep(true, &[(0, 1)]), []);
    }

    #[test]
    fn assembly_swept_clash_a_sub_assembly_rides_its_placements_link() {
        if !kernel_present() {
            return;
        }
        let rig = rig(Some(&hand()));
        let names = rig.parts().unwrap();
        assert_eq!(names, ["base", "hand/tip", "hand/nub", "chord", "circle", "carriage"]);
        let rows = sweep(&rig, &SWING).unwrap();
        assert_eq!(names_of(&names, &rows), [("hand/tip".to_string(), "circle".to_string())], "{rows:?}");
    }

    /// The wrapper's own refusals (keyframes naming other joints, a joint given twice, a value
    /// count that changes), then the kernel's, passed on. An `allowed` pair that is not two
    /// indices cannot be written in Rust: a pair is `(u32, u32)`.
    #[test]
    fn assembly_swept_clash_refuses_in_the_kernels_words() {
        if !kernel_present() {
            return;
        }
        let rig = rig(Some(&hand()));
        let refused = |keyframes: &[Keyframe]| message(sweep(&rig, keyframes));
        assert_eq!(
            refused(&[&[("hinge", &[0.0]), ("slide", &[0.0, 0.0])], &[("hinge", &[1.0]), ("slide", &[0.0, 0.0])], &[("hinge", &[2.0])]]),
            "swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2"
        );
        assert_eq!(
            refused(&[&[("hinge", &[0.0])], &[("hinge", &[1.0]), ("slide", &[0.0, 0.0])]]),
            "swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0"
        );
        assert_eq!(refused(&[&[("hinge", &[0.0])], &[("hinge", &[1.0]), ("hinge", &[2.0])]]), "swept_clash: joint 'hinge' is given twice");
        assert_eq!(
            refused(&[&[("slide", &[0.0, 0.0])], &[("slide", &[1.0])]]),
            "swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1"
        );
        // the kernel's own
        assert_eq!(
            refused(&[&[("hand/turn", &[0.0])], &[("hand/turn", &[1.0])]]),
            "swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints"
        );
        assert_eq!(refused(&[&[("elbow", &[0.0])], &[("elbow", &[1.0])]]), "swept_clash: no joint named 'elbow' in assembly 'rig' or under it");
        assert_eq!(
            refused(&[&[("hinge", &[0.0, 0.0])], &[("hinge", &[1.0, 1.0])]]),
            "swept_clash: joint 'hinge' takes 1 values, but 2 were given"
        );
        let two: [Keyframe; 2] = [&[("hinge", &[0.0])], &[("hinge", &[1.0])]];
        assert_eq!(refused(&two[..1]), "swept_clash: 1 poses, at least 2 are needed");
        let with = |resolution: f64, max_steps: u32, allowed: &[(u32, u32)], ground: Option<&str>| {
            message(rig.swept_clash(&two, 0.0, SWEPT_TOL, resolution, max_steps, allowed, ground, false))
        };
        let m = with(0.0, 100_000, &[], None);
        assert!(m.starts_with("swept_clash: resolution 0"), "{m:?}");
        assert_eq!(with(1e-3, 0, &[], None), "swept_clash: max_steps must be at least 1");
        assert_eq!(with(1e-3, 100_000, &[(9, 0)], None), "swept_clash: allowed pair (9, 0) names a part out of range");
        assert_eq!(with(1e-3, 100_000, &[], Some("wheel")), "swept_clash: assembly 'rig' has no link named 'wheel'");
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
        let err = spline.to_arcs(-1.0).unwrap_err();
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

    fn machine_job(block: &Solid) -> Job {
        let stock = Stock::around(block, 2.0).unwrap();
        Job::new(&stock, 30.0, JOB_DEFAULT_CLEARANCE, JOB_DEFAULT_TOLERANCE, JOB_DEFAULT_NAME, JOB_DEFAULT_SPINDLE_DWELL, JOB_DEFAULT_RESOLUTION).unwrap()
    }

    #[test]
    fn a_report_item_carries_the_z_range_of_its_corner() {
        let block = pocketed_block();
        let end_mill = Tool::flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let report = machine_job(&block).machine(&block, &end_mill, &[], None, None, 0.3, None).unwrap();
        assert_eq!(report.items().len(), 4);
        for item in report.items() {
            assert!((item.top - 10.0).abs() < 1e-6, "{}", item.top);
            assert!((item.bottom - 2.0).abs() < 1e-6, "{}", item.bottom);
        }
    }

    #[test]
    fn a_second_end_mill_takes_the_corners_the_first_misses() {
        let block = pocketed_block();
        let t1 = Tool::flat(1, 6.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let t2 = Tool::flat(2, 2.0, 20.0, 800.0, 200.0, 12000.0, TOOL_DEFAULT_RAMP_ANGLE).unwrap();
        let mut job = machine_job(&block);
        let report = job.machine_with(&block, &[&t1, &t2], &[], None, None, 0.3, None).unwrap();
        assert_eq!(report.items().len(), 4);
        for item in report.items() {
            assert!(item.reason.contains("T2 (2 mm)"), "{}", item.reason);
            assert!((item.top - 10.0).abs() < 1e-6, "{}", item.top);
            assert!((item.bottom - 2.0).abs() < 1e-6, "{}", item.bottom);
        }
        assert!(job.operations().unwrap().iter().any(|o| o.kind == "pocket" && o.tool == 2));
    }

    #[test]
    fn an_empty_end_mill_list_is_refused_and_leaves_the_job() {
        let block = pocketed_block();
        let mut job = machine_job(&block);
        let err = job.machine_with(&block, &[], &[], None, None, 0.3, None).unwrap_err();
        assert!(err.to_string().contains("machine: at least one end mill is needed"), "{err}");
        assert!(job.operations().unwrap().is_empty());
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

    // ---- oriented box, lengths, containment, closest (measure plan 3) -----------------

    fn near(a: f64, b: f64, tol: f64, what: &str) {
        assert!((a - b).abs() <= tol, "{what}: {a} vs {b} (tolerance {tol})");
    }

    fn near3(a: [f64; 3], b: [f64; 3], tol: f64, what: &str) {
        for i in 0..3 {
            near(a[i], b[i], tol, what);
        }
    }

    fn message<T: fmt::Debug>(r: Result<T>) -> String {
        r.expect_err("the library should have refused this").message().to_string()
    }

    #[test]
    fn the_oriented_box_of_a_turned_cuboid() {
        if !kernel_present() {
            return;
        }
        let turned = Solid::cuboid(2.0, 3.0, 4.0)
            .unwrap()
            .rotate(&[[0.0, 0.0, 0.0], [0.0, 0.0, 1.0]], 30f64.to_radians())
            .unwrap();
        let b = turned.oriented_box(1e-9).unwrap();
        let mut half = b.half;
        half.sort_by(|x, y| x.partial_cmp(y).unwrap());
        for (got, want) in half.iter().zip([1.0, 1.5, 2.0]) {
            assert!(got - want >= -1e-9 && got - want <= 1e-3, "half {half:?}");
        }
        for c in b.centre {
            near(c, 0.0, 1e-3, "centre");
        }
        for i in 0..3 {
            for j in 0..3 {
                let dot: f64 = (0..3).map(|k| b.axes[i][k] * b.axes[j][k]).sum();
                near(dot, if i == j { 1.0 } else { 0.0 }, 1e-9, "axes");
            }
        }
    }

    #[test]
    fn the_oriented_box_defaults_and_refusals() {
        if !kernel_present() {
            return;
        }
        let cylinder = Solid::cylinder(1.0, 2.0).unwrap();
        let default = cylinder.oriented_box(1e-5).unwrap();
        assert_eq!(cylinder.oriented_box(0.0).unwrap(), default);
        assert_eq!(cylinder.oriented_box(-1.0).unwrap(), default);
        for h in default.half {
            near(h, 1.0 + 3.125e-5 * 12f64.sqrt(), 1e-12, "grown half");
        }
        let nan = message(cylinder.oriented_box(f64::NAN));
        assert!(nan.starts_with("oriented_box: ") && nan.contains("is not an accuracy"), "{nan}");
        let sheet = Solid::cuboid(1.0, 2.0, 3.0).unwrap().face_sheet(0).unwrap();
        assert!(message(sheet.oriented_box(0.0)).starts_with("oriented_box: "));
    }

    #[test]
    fn a_circle_edge_measures_five_pi() {
        if !kernel_present() {
            return;
        }
        let cylinder = Solid::cylinder(2.5, 4.0).unwrap();
        let mut circles = 0;
        for edge in cylinder.edges().unwrap() {
            if edge.kind != "circle" {
                continue;
            }
            circles += 1;
            let l = cylinder.edge_length(edge.index, 1e-9).unwrap();
            near(l.length, 5.0 * std::f64::consts::PI, l.error.max(1e-9), "circle length");
            assert!(l.error >= 0.0 && l.error <= 1e-6 * l.length, "{l:?}");
            assert!(l.accuracy_met && !l.from_polyline, "{l:?}");
        }
        assert!(circles >= 1, "no circle edge found");
        let cube = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        let past = cube.edges().unwrap().len() as u32;
        assert!(message(cube.edge_length(past, 0.0)).starts_with("edge_length: "));
    }

    #[test]
    fn a_slot_profile_measures_its_perimeter() {
        if !kernel_present() {
            return;
        }
        let slot = Profile::slot([0.0, 0.0], 8.0, 1.0).unwrap();
        let l = slot.length(1e-9).unwrap();
        near(l.length, 12.0 + 2.0 * std::f64::consts::PI, l.error.max(1e-9), "slot perimeter");
        assert!(l.error >= 0.0 && l.error <= 1e-6 * l.length, "{l:?}");
        assert!(l.accuracy_met, "{l:?}");
        assert!(message(slot.length(f64::NAN)).starts_with("profile_length: "));
    }

    // ---- arc-length sampling (arc-length plan 3) ---------------------------------------

    fn dist(a: [f64; 3], b: [f64; 3]) -> f64 {
        ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
    }

    #[test]
    fn a_rim_a_quarter_of_the_way_round_is_a_quarter_turn() {
        if !kernel_present() {
            return;
        }
        let pi = std::f64::consts::PI;
        let cylinder = Solid::cylinder(2.5, 4.0).unwrap();
        let mut circles = 0;
        for edge in cylinder.edges().unwrap() {
            if edge.kind != "circle" {
                continue;
            }
            circles += 1;
            let curve = edge.curve.as_ref().unwrap();
            let start = cylinder.edge_point_at_length(edge.index, 0.0, 1e-9).unwrap();
            assert_eq!(start.parameter, curve.t0);
            let q = cylinder.edge_point_at_length(edge.index, 2.5 * pi / 2.0, 1e-9).unwrap();
            near(q.parameter, curve.t0 + pi / 2.0, 1e-9, "quarter parameter");
            near(dist(q.point, curve.origin), 2.5, 1e-9, "on the circle");
            near(dist(q.tangent, [0.0; 3]), 1.0, 1e-12, "unit tangent");
            assert!(q.segment.is_none() && !q.from_polyline, "{q:?}");
            assert!(q.error.is_finite() && q.error >= 0.0, "{q:?}");
            let four = cylinder.edge_divide_by_count(edge.index, 4, 1e-9).unwrap();
            assert_eq!(four.len(), 4);
            for k in 0..4 {
                near(dist(four[k].point, four[(k + 1) % 4].point), 2.5 * 2f64.sqrt(), 1e-9, "chord");
            }
            near3(four[0].point, start.point, 1e-9, "first is the start");
            assert_eq!(cylinder.edge_divide_by_length(edge.index, 2.5 * pi / 2.0, 1e-9).unwrap().len(), 4);
        }
        assert!(circles >= 2, "circle edges: {circles}");
    }

    #[test]
    fn an_open_edge_divides_end_to_end() {
        if !kernel_present() {
            return;
        }
        let cuboid = Solid::cuboid(2.0, 3.0, 4.0).unwrap();
        let mut found = false;
        for edge in cuboid.edges().unwrap() {
            if edge.kind != "line" || (cuboid.edge_length(edge.index, 1e-9).unwrap().length - 4.0).abs() > 1e-9 {
                continue;
            }
            found = true;
            let curve = edge.curve.as_ref().unwrap();
            let five = cuboid.edge_divide_by_count(edge.index, 4, 1e-9).unwrap();
            assert_eq!(five.len(), 5);
            for (k, at) in five.iter().enumerate() {
                near(dist(at.point, five[0].point), k as f64, 1e-9, "distance from the start");
            }
            assert_eq!(five[0].parameter, curve.t0);
            assert_eq!(five[4].parameter, curve.t1);
            let by_length = cuboid.edge_divide_by_length(edge.index, 1.5, 1e-9).unwrap();
            assert_eq!(by_length.len(), 3);
            for (k, want) in [0.0, 1.5, 3.0].into_iter().enumerate() {
                near(dist(by_length[k].point, by_length[0].point), want, 1e-9, "step");
            }
            break;
        }
        assert!(found, "no line edge of length 4");
    }

    #[test]
    fn a_slot_samples_by_side() {
        if !kernel_present() {
            return;
        }
        let pi = std::f64::consts::PI;
        let slot = Profile::slot([0.0, 0.0], 8.0, 1.0).unwrap();
        let at = slot.point_at_length(6.0 + pi / 2.0, 1e-9).unwrap();
        near3(at.point, [4.0, 0.0, 0.0], 1e-9, "the slot's far end");
        assert_eq!(at.segment, Some(1));
        let eight = slot.divide_by_count(8, 1e-9).unwrap();
        assert_eq!(eight.len(), 8);
        assert!(eight.iter().all(|a| matches!(a.segment, Some(s) if s < 4)), "{eight:?}");
        let by_length = slot.divide_by_length(3.0, 1e-9).unwrap();
        assert_eq!(by_length.len(), ((12.0 + 2.0 * pi) / 3.0).floor() as usize + 1);
        for (k, got) in by_length.iter().enumerate() {
            let want = slot.point_at_length(3.0 * k as f64, 1e-9).unwrap();
            near3(got.point, want.point, 1e-12, "sample against point_at_length");
            assert_eq!(got.segment, want.segment);
        }
        assert!(dist(by_length[by_length.len() - 1].point, by_length[0].point) > 0.1);
    }

    #[test]
    fn arc_length_refusals_name_their_call() {
        if !kernel_present() {
            return;
        }
        let cylinder = Solid::cylinder(2.5, 4.0).unwrap();
        let rim = cylinder.edges().unwrap().into_iter().find(|e| e.kind == "circle").unwrap().index;
        let past = cylinder.edges().unwrap().len() as u32;
        for s in [-1.0, 100.0] {
            assert!(message(cylinder.edge_point_at_length(rim, s, 0.0)).starts_with("edge_point_at_length: "));
        }
        assert!(message(cylinder.edge_point_at_length(past, 1.0, 0.0)).starts_with("edge_point_at_length: "));
        let zero = message(cylinder.edge_divide_by_count(rim, 0, 0.0));
        assert!(zero.starts_with("edge_divide_by_count: ") && zero.contains("not at least 1"), "{zero}");
        let big = message(cylinder.edge_divide_by_count(rim, 1_000_001, 0.0));
        assert!(big.starts_with("edge_divide_by_count: ") && big.contains("not at most 1000000"), "{big}");
        assert!(message(cylinder.edge_divide_by_length(rim, 0.0, 0.0)).starts_with("edge_divide_by_length: "));
        let nan = message(cylinder.edge_point_at_length(rim, 1.0, f64::NAN));
        assert!(nan.starts_with("edge_point_at_length: ") && nan.contains("is not an accuracy"), "{nan}");
        let slot = Profile::slot([0.0, 0.0], 8.0, 1.0).unwrap();
        assert!(message(slot.point_at_length(-1.0, 0.0)).starts_with("profile_point_at_length: "));
        assert!(message(slot.divide_by_count(0, 0.0)).starts_with("profile_divide_by_count: "));
        assert!(message(slot.divide_by_length(-1.0, 0.0)).starts_with("profile_divide_by_length: "));
    }

    #[test]
    fn arc_length_default_accuracy_is_an_option() {
        if !kernel_present() {
            return;
        }
        let slot = Profile::slot([0.0, 0.0], 8.0, 1.0).unwrap();
        let default = slot.point_at_length(5.0, 0.0).unwrap();
        assert_eq!(slot.point_at_length(5.0, -1.0).unwrap(), default);
        assert!(default.error.is_finite());
    }

    // ---- NurbsCurve (Python's test_a_nurbs_curve_* and its neighbours, trimmed to the marshalling) ----

    /// A quarter of the circle of radius `r` in the xy plane, exact (rational quadratic).
    fn quarter_circle(r: f64) -> NurbsCurve {
        NurbsCurve::new(&[[r, 0.0, 0.0], [r, r, 0.0], [0.0, r, 0.0]], 2, Some(&[1.0, 0.5f64.sqrt(), 1.0]), None).unwrap()
    }

    /// The whole circle of radius `r` about the z axis at height `z`, exact (nine-point rational
    /// quadratic).
    fn whole_circle(r: f64, z: f64) -> NurbsCurve {
        let h = 0.5f64.sqrt();
        let pts = [[r, 0.0, z], [r, r, z], [0.0, r, z], [-r, r, z], [-r, 0.0, z], [-r, -r, z], [0.0, -r, z], [r, -r, z], [r, 0.0, z]];
        NurbsCurve::new(
            &pts,
            2,
            Some(&[1.0, h, 1.0, h, 1.0, h, 1.0, h, 1.0]),
            Some(&[0.0, 0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0, 1.0]),
        )
        .unwrap()
    }

    fn ends(c: &NurbsCurve) -> ([f64; 3], [f64; 3]) {
        let (lo, hi) = c.domain().unwrap();
        (c.point(lo).unwrap(), c.point(hi).unwrap())
    }

    /// Each tween's ends are `a`'s and `b`'s blended at `(i + 1) / (len + 1)`.
    fn ends_blended(a: &NurbsCurve, b: &NurbsCurve, tweens: &[NurbsCurve], tol: f64) {
        let ((a0, a1), (b0, b1)) = (ends(a), ends(b));
        for (i, t) in tweens.iter().enumerate() {
            let f = (i + 1) as f64 / (tweens.len() + 1) as f64;
            let mix = |p: [f64; 3], q: [f64; 3]| [p[0] + f * (q[0] - p[0]), p[1] + f * (q[1] - p[1]), p[2] + f * (q[2] - p[2])];
            let (t0, t1) = ends(t);
            assert!(dist(t0, mix(a0, b0)) < tol && dist(t1, mix(a1, b1)) < tol, "tween {i}: {t0:?} {t1:?}");
        }
    }

    #[test]
    fn a_nurbs_curve_reads_back_what_it_was_built_from() {
        if !kernel_present() {
            return;
        }
        let pi = std::f64::consts::PI;
        let h = 0.5f64.sqrt();
        let c = quarter_circle(2.0);
        assert_eq!(c.degree(), 2);
        assert!(c.is_rational() && !c.is_closed());
        assert_eq!(c.control_points().unwrap(), vec![[2.0, 0.0, 0.0], [2.0, 2.0, 0.0], [0.0, 2.0, 0.0]]);
        assert_eq!(c.weights().unwrap(), vec![1.0, h, 1.0]);
        assert_eq!(c.knots().unwrap(), vec![0.0, 0.0, 0.0, 1.0, 1.0, 1.0]);
        assert_eq!(c.domain().unwrap(), (0.0, 1.0));
        assert_eq!(c.fit_error(), None);
        near(dist(c.point(0.37).unwrap(), [0.0; 3]), 2.0, 1e-12, "radius");
        let k = c.curvature(0.5).unwrap();
        near(k.kappa, 0.5, 1e-12, "kappa");
        near3(k.centre.expect("a bend has a centre"), [0.0; 3], 1e-12, "centre");
        near(c.length(0.0).unwrap().length, pi, 1e-9, "length");
        let at = c.point_at_length(pi / 2.0, 0.0).unwrap();
        near3(at.point, [h * 2.0, h * 2.0, 0.0], 1e-9, "point at length");
        assert_eq!(at.segment, None);
        assert_eq!(c.divide_by_count(4, 0.0).unwrap().len(), 5);
        assert_eq!(c.divide_by_length(1.0, 0.0).unwrap().len(), 4);
        let d = c.derivatives(0.0, 2).unwrap();
        assert_eq!(d.len(), 3);
        assert_eq!(d[0], [2.0, 0.0, 0.0]);
        assert!(d[1][0].abs() < 1e-12 && d[1][1] > 0.0, "{d:?}");
        let line = NurbsCurve::new(&[[0.0; 3], [1.0, 0.0, 0.0]], 1, None, None).unwrap();
        let straight = line.curvature(0.5).unwrap();
        assert_eq!(straight.centre, None);
        assert_eq!(straight.kappa, 0.0);
        // Clone is the library's copy: it reads alike and outlives the original.
        let copy = c.clone();
        drop(c);
        assert_eq!(copy.control_points().unwrap().len(), 3);
    }

    #[test]
    fn a_curve_through_points_and_its_edits() {
        if !kernel_present() {
            return;
        }
        let pi = std::f64::consts::PI;
        let ring: Vec<[f64; 3]> = (0..10)
            .map(|i| {
                let a = 2.0 * pi * i as f64 / 10.0;
                [a.cos(), a.sin(), 0.2 * (3.0 * a).sin()]
            })
            .collect();
        let closed = NurbsCurve::through(&ring, 3, true, None, None).unwrap();
        assert!(closed.is_closed());
        assert_eq!(closed.divide_by_count(6, 0.0).unwrap().len(), 6);
        let pts = [[0.0, 0.0, 0.0], [1.0, 2.0, 0.5], [3.0, 1.0, -0.5], [4.0, 3.0, 1.0], [6.0, 2.0, 0.0]];
        let c = NurbsCurve::through(&pts, 3, false, Some([0.0, 0.0, 5.0]), None).unwrap();
        let (lo, hi) = c.domain().unwrap();
        let d = c.derivatives(lo, 1).unwrap()[1];
        assert!(d[0].abs() < 1e-9 && d[1].abs() < 1e-9 && d[2] > 0.0, "{d:?}");
        let sine: Vec<[f64; 3]> = (0..200).map(|t| [t as f64 / 50.0, (t as f64 / 50.0).sin(), 0.0]).collect();
        let fit = NurbsCurve::fit(&sine, 3, Some(1e-4)).unwrap();
        let err = fit.fit_error().expect("a fit reports its error");
        assert!((0.0..=1e-4).contains(&err), "{err}");
        // A curve built by hand reports none; so does every edit that does not fit.
        assert_eq!(c.fit_error(), None);
        assert_eq!(c.reversed().unwrap().fit_error(), None);
        assert!(dist(c.reversed().unwrap().point(lo).unwrap(), c.point(hi).unwrap()) < 1e-12);
        let mid = 0.5 * (lo + hi);
        assert_eq!(c.trimmed(lo, mid).unwrap().domain().unwrap(), (lo, mid));
        let longer = c.extended(0.5, false).unwrap();
        assert!(longer.domain().unwrap().1 > hi);
        assert!(dist(longer.point(hi).unwrap(), c.point(hi).unwrap()) < 1e-9);
        let before = c.extended(0.5, true).unwrap();
        assert!(before.domain().unwrap().0 < lo);
        assert_eq!(c.elevated(2).unwrap().degree(), 5);
    }

    #[test]
    fn curves_join_end_to_end() {
        if !kernel_present() {
            return;
        }
        let lead = NurbsCurve::new(&[[2.0, -3.0, 0.0], [2.0, 0.0, 0.0]], 1, None, None).unwrap();
        let arc = quarter_circle(2.0);
        let tail = NurbsCurve::new(
            &[[0.0, 2.0, 0.0], [-1.0, 2.5, 0.0], [-2.0, 2.0, 1.0], [-3.0, 3.0, 0.0], [-4.0, 2.0, 0.0], [-5.0, 2.0, 2.0]],
            5,
            None,
            None,
        )
        .unwrap();
        let back = arc.reversed().unwrap();
        let j = NurbsCurve::joined(&[&lead, &back, &tail], 1e-6).unwrap();
        assert_eq!(j.degree(), 5);
        assert_eq!(j.domain().unwrap(), (0.0, 3.0));
        for (t, want) in [(0.0, [2.0, -3.0, 0.0]), (1.0, [2.0, 0.0, 0.0]), (2.0, [0.0, 2.0, 0.0]), (3.0, [-5.0, 2.0, 2.0])] {
            assert!(dist(j.point(t).unwrap(), want) < 1e-12, "t = {t}");
        }
        for i in 0..=20 {
            let s = i as f64 / 20.0;
            near(dist(j.point(1.0 + s).unwrap(), [0.0; 3]), 2.0, 1e-12, "on the circle");
            assert!(dist(j.point(2.0 + s).unwrap(), tail.point(s).unwrap()) < 1e-12);
        }
        assert_eq!(NurbsCurve::joined(&[&arc], 1e-6).unwrap().control_points().unwrap(), arc.control_points().unwrap());
        let gap = message(NurbsCurve::joined(&[&lead, &tail], 1e-6));
        assert!(gap.starts_with("nurbs_curve_joined: curve 1 ") && gap.contains("curve 0"), "{gap}");
        assert!(message(NurbsCurve::joined(&[], 1e-6)).starts_with("nurbs_curve_joined: "));
    }

    fn tween_pair() -> (NurbsCurve, NurbsCurve) {
        let a = NurbsCurve::new(&[[0.0, 0.0, 0.0], [3.0, 2.0, 0.0], [6.0, -1.0, 0.0], [10.0, 0.0, 0.0]], 3, None, None).unwrap();
        let b = NurbsCurve::new(&[[0.0, 1.0, 5.0], [4.0, 4.0, 5.0], [7.0, -3.0, 6.0], [10.0, 1.0, 5.0]], 3, None, None).unwrap();
        (a, b)
    }

    #[test]
    fn tweens_blend_from_one_curve_to_another() {
        if !kernel_present() {
            return;
        }
        let (a, b) = tween_pair();
        let plain = a.tween(&b, 3, TweenMethod::Plain, None, true, None).unwrap();
        assert_eq!(plain.len(), 3);
        ends_blended(&a, &b, &plain, 1e-12);
        assert!(dist(plain[1].control_points().unwrap()[1], [3.5, 3.0, 2.5]) < 1e-12);
        let matching = a.tween(&b, 2, TweenMethod::Matching, None, true, None).unwrap();
        assert_eq!(matching.len(), 2);
        ends_blended(&a, &b, &matching, 1e-12);
        let sampled = a.tween(&b, 4, TweenMethod::Sampling, Some(20), true, None).unwrap();
        assert_eq!(sampled.len(), 4);
        assert!(sampled.iter().all(|t| t.degree() == 3));
        ends_blended(&a, &b, &sampled, 1e-9);
        assert_eq!(a.tween(&b, 1, TweenMethod::Matching, None, true, Some(0.0)).unwrap().len(), 1);
        // A quadratic against the cubic: plain refuses in the library's words; matching makes one.
        let q = NurbsCurve::new(&[[0.0, 1.0, 5.0], [5.0, 4.0, 5.0], [10.0, 1.0, 5.0]], 2, None, None).unwrap();
        let refused = message(a.tween(&q, 2, TweenMethod::Plain, None, true, None));
        assert!(refused.starts_with("nurbs_curve_tween: ") && refused.contains("compatible"), "{refused}");
        let mixed = a.tween(&q, 2, TweenMethod::Matching, None, true, None).unwrap();
        assert_eq!(mixed[0].degree(), 3);
        ends_blended(&a, &q, &mixed, 1e-12);
        assert!(message(a.tween(&b, 0, TweenMethod::Matching, None, true, None)).starts_with("nurbs_curve_tween: "));
    }

    #[test]
    fn tween_samples_and_method_are_checked() {
        if !kernel_present() {
            return;
        }
        let (a, b) = tween_pair();
        assert!(message(a.tween(&b, 2, TweenMethod::Sampling, None, true, None)).contains("sampling needs samples"));
        let read = message(a.tween(&b, 2, TweenMethod::Matching, Some(10), true, None));
        assert!(read.starts_with("nurbs_curve_tween: samples is read only by sampling"), "{read}");
        assert_eq!(TweenMethod::parse("plain").unwrap(), TweenMethod::Plain);
        let method = message(TweenMethod::parse("loft"));
        assert_eq!(method, "nurbs_curve_tween: method must be one of plain, matching, sampling, not 'loft'");
        let few = message(a.tween(&b, 2, TweenMethod::Sampling, Some(1), true, None));
        assert!(few.starts_with("nurbs_curve_tween: sampling needs at least"), "{few}");
    }

    #[test]
    fn tweens_of_two_circles_are_closed_circles() {
        if !kernel_present() {
            return;
        }
        let (small, big) = (whole_circle(2.0, 0.0), whole_circle(4.0, 6.0));
        let tweens = small.tween(&big, 3, TweenMethod::Matching, None, true, None).unwrap();
        assert_eq!(tweens.len(), 3);
        for (i, t) in tweens.iter().enumerate() {
            let f = (i + 1) as f64 / 4.0;
            assert!(t.is_closed(), "tween {i}");
            let (lo, hi) = t.domain().unwrap();
            for k in 0..24 {
                let [x, y, z] = t.point(lo + (hi - lo) * k as f64 / 24.0).unwrap();
                assert!((x.hypot(y) - (2.0 + 2.0 * f)).abs() < 1e-12 && (z - 6.0 * f).abs() < 1e-12, "tween {i} at {k}");
            }
        }
    }

    #[test]
    fn a_curve_from_an_edge_a_plane_and_a_sphere() {
        if !kernel_present() {
            return;
        }
        let cyl = Solid::cylinder(2.5, 4.0).unwrap();
        let rims: Vec<NurbsCurve> = cyl
            .edges()
            .unwrap()
            .iter()
            .filter(|e| e.kind == "circle")
            .map(|e| NurbsCurve::from_edge(&cyl, e.index).unwrap())
            .collect();
        assert!(rims.len() >= 2);
        for rim in &rims {
            let (lo, hi) = rim.domain().unwrap();
            for t in [lo, 0.5 * (lo + hi), hi] {
                let [x, y, _] = rim.point(t).unwrap();
                near(x.hypot(y), 2.5, 1e-12, "rim radius");
            }
        }
        let sphere = Solid::sphere(3.0).unwrap();
        let line = NurbsCurve::new(&[[-2.0, 0.5, 10.0], [2.0, -0.5, 10.0]], 1, None, None).unwrap();
        let on = line.projected_to_face(&sphere, 0, [0.0, 0.0, -1.0], Some(1e-4)).unwrap();
        assert!(on.fit_error().unwrap() <= 1e-4);
        let (lo, hi) = on.domain().unwrap();
        near(dist(on.point(0.5 * (lo + hi)).unwrap(), [0.0; 3]), 3.0, 1e-4, "projected onto the sphere");
        let pulled = line.pulled_to_face(&sphere, 0, Some(1e-4)).unwrap();
        assert!(pulled.fit_error().is_some());
        near(dist(pulled.point(pulled.domain().unwrap().0).unwrap(), [0.0; 3]), 3.0, 1e-4, "pulled onto the sphere");
        let through = NurbsCurve::new(&[[-5.0, 1.0, 1.0], [5.0, 1.0, 1.0]], 1, None, None).unwrap();
        let hits = through.face_hits(&sphere, 0, Some(1e-6)).unwrap();
        assert_eq!(hits.len(), 2);
        near(hits[0].point[0], -7f64.sqrt(), 1e-6, "first crossing");
        let crossing = through.plane_hits([0.0; 3], [1.0, 0.0, 0.0]).unwrap();
        assert_eq!(crossing.len(), 1);
        assert!(dist(crossing[0].point, [0.0, 1.0, 1.0]) < 1e-12);
        let flat = line.projected_to_plane([0.0, 0.0, 1.0], [0.0, 0.0, 1.0], None).unwrap();
        assert_eq!(flat.point(0.0).unwrap(), [-2.0, 0.5, 1.0]);
        let q = quarter_circle(2.0);
        let blend = NurbsCurve::blend(&q, true, &through, false, 2, 1.0).unwrap();
        assert_eq!(blend.degree(), 5);
        near(blend.curvature(0.0).unwrap().kappa, 0.5, 1e-9, "blend curvature");
        let teeth = q.comb(8, 1.0).unwrap();
        assert_eq!(teeth.len(), 9);
        assert!(teeth.iter().all(|&(p, t)| (dist(p, t) - 0.5).abs() < 1e-9));
        // A comb of no steps is one step.
        assert_eq!(q.comb(0, 1.0).unwrap().len(), 2);
    }

    #[test]
    fn nurbs_curve_refusals_name_the_call() {
        if !kernel_present() {
            return;
        }
        let q = quarter_circle(2.0);
        let two = [[0.0; 3], [1.0, 0.0, 0.0]];
        let cube = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        let rows = [
            ("nurbs_curve_new", message(NurbsCurve::new(&two, 9, None, None))),
            ("nurbs_curve_new", message(NurbsCurve::new(&two, 1, Some(&[1.0, -1.0]), None))),
            ("nurbs_curve_through", message(NurbsCurve::through(&two, 3, false, None, None))),
            ("nurbs_curve_fit", message(NurbsCurve::fit(&two, 1, Some(-1.0)))),
            ("nurbs_curve_from_edge", message(NurbsCurve::from_edge(&cube, 999))),
            ("nurbs_curve_from_face_isocurve", message(NurbsCurve::isocurve(&cube, 0, true, 0.5))),
            ("nurbs_curve_blend", message(NurbsCurve::blend(&q, true, &q, true, 3, 1.0))),
            ("nurbs_curve_projected_to_plane", message(q.projected_to_plane([0.0; 3], [0.0, 0.0, 1.0], Some([1.0, 0.0, 0.0])))),
            ("nurbs_curve_trimmed", message(q.trimmed(0.5, 0.2))),
            ("nurbs_curve_extended", message(q.extended(0.0, false))),
            ("nurbs_curve_point", message(q.point(2.0))),
            ("nurbs_curve_derivatives", message(q.derivatives(0.5, 9))),
            ("nurbs_curve_divide_by_count", message(q.divide_by_count(0, 0.0))),
            ("nurbs_curve_plane_hits", message(q.plane_hits([0.0; 3], [0.0, 0.0, 1.0]))),
        ];
        for (name, got) in rows {
            assert!(got.starts_with(&format!("{name}: ")), "{name}: {got}");
        }
        let weights = message(NurbsCurve::new(&two, 1, Some(&[1.0, 1.0, 1.0]), None));
        assert_eq!(weights, "nurbs_curve_new: 3 weights for 2 points; give one per point");
    }

    #[test]
    fn a_curve_maps_by_its_control_points_and_values_become_curves() {
        if !kernel_present() {
            return;
        }
        let c = NurbsCurve::new(&[[0.0; 3], [1.0, 1.0, 1.0], [2.0, 0.0, 0.0]], 2, Some(&[1.0, 0.5, 1.0]), None).unwrap();
        let moved = c.transformed(&Transform::translation([1.0, 2.0, 3.0]).unwrap()).unwrap();
        let (was, now) = (c.point(0.5).unwrap(), moved.point(0.5).unwrap());
        near3(now, [was[0] + 1.0, was[1] + 2.0, was[2] + 3.0], 1e-12, "translated point");
        assert_eq!(moved.weights().unwrap(), c.weights().unwrap());
        // A line value is a degree-1 curve through its ends.
        let line = Line::from_values(&[0.0, 0.0, 0.0, 2.0, 0.0, 0.0]).unwrap().to_nurbs().unwrap();
        assert_eq!(line.degree(), 1);
        let (lo, hi) = line.domain().unwrap();
        near3(line.point(0.5 * (lo + hi)).unwrap(), [1.0, 0.0, 0.0], 1e-12, "middle of the line");
        // A circle value is a closed rational curve at its radius all the way round.
        let value = Circle::from_values(&[1.0, -1.0, 2.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 3.0]).unwrap();
        let ring = value.to_nurbs().unwrap();
        assert!(ring.is_rational() && ring.is_closed());
        let (lo, hi) = ring.domain().unwrap();
        for k in 0..16 {
            let p = ring.point(lo + (hi - lo) * k as f64 / 16.0).unwrap();
            near(dist(p, [1.0, -1.0, 2.0]), 3.0, 1e-12, "circle radius");
        }
        // The same through the sum type.
        let any: CurveValue = value.into();
        assert!(any.to_nurbs().unwrap().is_closed());
    }

    #[test]
    fn curves_outlive_what_they_came_from() {
        if !kernel_present() {
            return;
        }
        let (a, b) = tween_pair();
        let tweens = a.tween(&b, 2, TweenMethod::Matching, None, true, None).unwrap();
        drop(a);
        drop(b);
        for t in &tweens {
            assert_eq!(t.degree(), 3);
            assert_eq!(t.control_points().unwrap().len(), 4);
        }
        let rim = {
            let cyl = Solid::cylinder(2.5, 4.0).unwrap();
            let edge = cyl.edges().unwrap().into_iter().find(|e| e.kind == "circle").unwrap();
            NurbsCurve::from_edge(&cyl, edge.index).unwrap()
        };
        let (lo, hi) = rim.domain().unwrap();
        let [x, y, _] = rim.point(0.5 * (lo + hi)).unwrap();
        near(x.hypot(y), 2.5, 1e-12, "a rim read after its solid is gone");
        let shared = std::sync::Arc::new(rim);
        let other = std::sync::Arc::clone(&shared);
        std::thread::spawn(move || other.degree()).join().unwrap();
    }

    // ---- Sheets from curves (Python's test_surfaces_from_curves_are_sheets and its neighbours) ----

    fn seg(a: [f64; 3], b: [f64; 3]) -> NurbsCurve {
        NurbsCurve::new(&[a, b], 1, None, None).unwrap()
    }

    /// A `w` by `h` rectangle centred at `origin` in the plane of `x`, `y`, facing `x cross y`.
    fn rect_sheet(origin: [f64; 3], x: [f64; 3], y: [f64; 3], w: f64, h: f64) -> Solid {
        let z = [x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]];
        Solid::face(&Profile::rect(w, h).unwrap(), &Frame::new(origin, x, y, z).unwrap()).unwrap()
    }

    /// The circle of radius `r` about `centre` in its z plane: nine rational quadratic points.
    fn exact_circle(centre: [f64; 3], r: f64) -> NurbsCurve {
        let s = 0.5f64.sqrt();
        let pts: Vec<[f64; 3]> = [(1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (-1.0, 1.0), (-1.0, 0.0), (-1.0, -1.0), (0.0, -1.0), (1.0, -1.0), (1.0, 0.0)]
            .iter()
            .map(|(a, b)| [centre[0] + r * a, centre[1] + r * b, centre[2]])
            .collect();
        NurbsCurve::new(
            &pts,
            2,
            Some(&[1.0, s, 1.0, s, 1.0, s, 1.0, s, 1.0]),
            Some(&[0.0, 0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0, 1.0]),
        )
        .unwrap()
    }

    fn area_of(s: &Solid) -> f64 {
        s.mass(1e-6).unwrap().area
    }

    #[test]
    fn surfaces_from_curves_are_sheets() {
        if !kernel_present() {
            return;
        }
        let c = [[-1.0, -1.0, 1.0], [1.0, -1.0, -1.0], [1.0, 1.0, 1.0], [-1.0, 1.0, -1.0]];
        let sides = [seg(c[0], c[1]), seg(c[1], c[2]), seg(c[2], c[3]), seg(c[3], c[0])];
        let coons = Solid::edge_surface(&[&sides[0], &sides[1], &sides[2], &sides[3]], Some(1e-9)).unwrap();
        assert_eq!(coons.faces().unwrap(), 1);
        assert_eq!(coons.sheet_error(), Some(0.0));
        let (l0, l1) = (seg([0.0; 3], [2.0, 0.0, 0.0]), seg([0.0, 1.0, 1.0], [2.0, 1.0, -1.0]));
        let loft = Solid::loft_curves(&[&l0, &l1], 3, false, false).unwrap();
        assert_eq!(loft.faces().unwrap(), 1);
        assert_eq!(loft.sheet_error(), None);
        assert!(loft.patch_report().is_none());
        let plain = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        assert!(plain.sheet_error().is_none() && plain.patch_report().is_none());
        let ring: Vec<[f64; 3]> = (0..8).map(|i| {
            let t = 2.0 * std::f64::consts::PI * f64::from(i) / 8.0;
            [t.cos(), t.sin(), 0.0]
        }).collect();
        let circle = NurbsCurve::through(&ring, 3, true, None, None).unwrap();
        let rail = seg([0.0; 3], [0.0, 0.0, 4.0]);
        let tube = Solid::sweep_rail(&rail, &[&circle], SweepFrame::Rmf, None, Some(1e-5)).unwrap();
        assert_eq!(tube.faces().unwrap(), 1);
        let e = tube.sheet_error().expect("a swept sheet reports its fit");
        assert!((0.0..=1e-5).contains(&e), "{e}");
        let upright = Solid::sweep_rail(&rail, &[&circle], SweepFrame::Fixed, Some([0.0, 1.0, 0.0]), Some(1e-5)).unwrap();
        assert_eq!(upright.faces().unwrap(), 1);
        assert!(upright.sheet_error().is_some());
        let (ra, rb) = (seg([-1.0, 0.0, 0.0], [-1.0, 5.0, 0.0]), seg([1.0, 0.0, 0.0], [1.0, 5.0, 0.0]));
        let across = seg([-1.0, 0.0, 0.0], [1.0, 0.0, 0.0]);
        let band = Solid::sweep_two_rails(&ra, &rb, &[&across], Some(1e-6)).unwrap();
        assert_eq!(band.faces().unwrap(), 1);
        assert!(band.sheet_error().is_some());
        let us: Vec<NurbsCurve> = [-1.0, 0.2, 1.0].iter().map(|&y| seg([-1.0, y, -y], [1.0, y, y])).collect();
        let vs: Vec<NurbsCurve> = [-1.0, 0.3, 1.0].iter().map(|&x| seg([x, -1.0, -x], [x, 1.0, x])).collect();
        let net = Solid::network_surface(&[&us[0], &us[1], &us[2]], &[&vs[0], &vs[1], &vs[2]], Some(1e-9)).unwrap();
        assert_eq!(net.faces().unwrap(), 1);
        assert!(net.sheet_error().unwrap() <= 1e-9);
        let one = seg([0.0; 3], [1.0, 0.0, 0.0]);
        let other = seg([0.0; 3], [0.0, 1.0, 0.0]);
        for (name, got) in [
            ("loft_curves", message(Solid::loft_curves(&[&circle], 3, false, false))),
            ("edge_surface", message(Solid::edge_surface(&[&one], Some(1e-3)))),
            ("network_surface", message(Solid::network_surface(&[&one], &[&other], Some(1e-3)))),
        ] {
            assert!(got.starts_with(&format!("{name}: ")), "{name}: {got}");
        }
        // The refusals the wrapper makes itself, in Python's words.
        assert_eq!("twisty".parse::<SweepFrame>().unwrap_err().message(), "sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'");
        assert_eq!("fixed".parse::<SweepFrame>().unwrap(), SweepFrame::Fixed);
        assert_eq!("x".parse::<SheetSide>().unwrap_err().message(), "a side is 'u0', 'u1', 'v0' or 'v1', not 'x'");
        assert_eq!("v1".parse::<SheetSide>().unwrap(), SheetSide::V1);
        assert_eq!(
            "middle".parse::<TrimKeep>().unwrap_err().message(),
            "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'"
        );
        assert_eq!("left".parse::<TrimKeep>().unwrap(), TrimKeep::Left);
    }

    #[test]
    fn a_curve_trims_a_hole_and_an_island_and_they_join_back() {
        if !kernel_present() {
            return;
        }
        let sheet = rect_sheet([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 20.0, 20.0);
        let ring = exact_circle([1.0, -2.0, 0.0], 5.0);
        let pi = std::f64::consts::PI;
        let holed = sheet.trim_by_curve(&ring, TrimKeep::Outside, Some([0.0, 0.0, -1.0]), Some(0.01)).unwrap();
        let island = sheet.trim_by_curve(&ring, TrimKeep::Inside, None, Some(0.01)).unwrap();
        near(area_of(&island), 25.0 * pi, 1e-6, "island area");
        near(area_of(&holed), 400.0 - 25.0 * pi, 1e-6, "holed area");
        let split = sheet.split_by_curve(&ring, None, Some(0.01)).unwrap();
        assert_eq!(split.faces().unwrap(), 2);
        let (back, report) = Solid::join_sheets(&[&holed, &island], None).unwrap();
        assert!(report.sewn >= 1 && report.naked_after == report.naked_before - 2 * report.sewn && !report.closed, "{report:?}");
        assert_eq!(back.faces().unwrap(), 2);
        assert!(back.sheet_error().is_none() && back.patch_report().is_none());
    }

    #[test]
    fn an_open_curve_keeps_its_left_or_right() {
        if !kernel_present() {
            return;
        }
        let sheet = rect_sheet([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 20.0, 20.0);
        let line = NurbsCurve::through(&[[-5.0, 1.0, 0.0], [5.0, 1.0, 0.0]], 1, false, None, None).unwrap();
        let up = Some([0.0, 0.0, 1.0]);
        let left = sheet.trim_by_curve(&line, TrimKeep::Left, up, Some(0.01)).unwrap();
        let right = sheet.trim_by_curve(&line, TrimKeep::Right, up, Some(0.01)).unwrap();
        near(area_of(&left), 180.0, 1e-9, "left");
        near(area_of(&right), 220.0, 1e-9, "right");
        let inside = sheet.trim_by_curve(&line, TrimKeep::Inside, Some([0.0, 0.0, -1.0]), Some(0.01)).unwrap();
        near(area_of(&inside), 220.0, 1e-9, "inside, seen from below");
        let outside = sheet.trim_by_curve(&line, TrimKeep::Outside, up, Some(0.01)).unwrap();
        near(area_of(&outside), 220.0, 1e-9, "outside is the right");
    }

    #[test]
    fn six_sheets_join_into_a_box_the_kernel_measures_cuts_and_writes() {
        if !kernel_present() {
            return;
        }
        let (x, y, z) = ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
        let faces = [
            rect_sheet([5.0, 10.0, 0.0], x, y, 10.0, 20.0),
            rect_sheet([5.0, 10.0, 30.0], x, y, 10.0, 20.0),
            rect_sheet([0.0, 10.0, 15.0], y, z, 20.0, 30.0),
            rect_sheet([10.0, 10.0, 15.0], y, z, 20.0, 30.0),
            rect_sheet([5.0, 0.0, 15.0], z, x, 30.0, 10.0),
            rect_sheet([5.0, 20.0, 15.0], x, z, 10.0, 30.0),
        ];
        let refs: Vec<&Solid> = faces.iter().collect();
        let (boxed, report) = Solid::join_sheets(&refs, None).unwrap();
        assert_eq!((report.sewn, report.naked_before, report.naked_after, report.turned, report.closed), (12, 24, 0, 4, true), "{report:?}");
        let m = boxed.mass(1e-6).unwrap();
        assert!(m.closed);
        near(m.volume, 6000.0, 1e-6, "box volume");
        let bored = boxed.cut(&Solid::cylinder(2.0, 50.0).unwrap().translate(5.0, 10.0, -10.0).unwrap(), 0.01).unwrap();
        near(bored.mass(1e-6).unwrap().volume, 6000.0 - std::f64::consts::PI * 4.0 * 30.0, 0.05, "bored volume");
        assert!(boxed.step_text(None, Unit::Millimetre).unwrap().contains("CLOSED_SHELL"));
        // Two of the faces, one moved a thousandth away: sewn only at a tolerance that covers it.
        let moved = faces[3].translate(0.0, 0.0, 1e-3).unwrap();
        let (_, apart) = Solid::join_sheets(&[&faces[1], &moved], None).unwrap();
        let (_, loose) = Solid::join_sheets(&[&faces[1], &moved], Some(2e-3)).unwrap();
        assert_eq!((apart.sewn, loose.sewn), (0, 1));
        near(loose.worst_gap, 1e-3, 1e-9, "worst gap");
    }

    #[test]
    fn join_sheets_sews_a_t_junction() {
        if !kernel_present() {
            return;
        }
        let rect = |x0: f64, y0: f64, x1: f64, y1: f64| {
            let c = [[x0, y0, 0.0], [x1, y0, 0.0], [x1, y1, 0.0], [x0, y1, 0.0]];
            let s = [seg(c[0], c[1]), seg(c[1], c[2]), seg(c[2], c[3]), seg(c[3], c[0])];
            Solid::edge_surface(&[&s[0], &s[1], &s[2], &s[3]], Some(1e-3)).unwrap()
        };
        // Two unit squares on a 2 x 1 rectangle's long edge: it is cut where they meet on it.
        let (big, a, b) = (rect(0.0, 0.0, 2.0, 1.0), rect(0.0, 1.0, 1.0, 2.0), rect(1.0, 1.0, 2.0, 2.0));
        let (_, exact) = Solid::join_sheets(&[&big, &a, &b], None).unwrap();
        assert_eq!(exact.sewn, 1);
        let (shell, report) = Solid::join_sheets(&[&big, &a, &b], Some(1e-3)).unwrap();
        assert_eq!((report.sewn, report.naked_before, report.naked_after, report.closed), (3, 13, 7, false), "{report:?}");
        assert_eq!(shell.faces().unwrap(), 3);
    }

    #[test]
    fn recess_sets_a_square_window_into_a_flat_sheet() {
        if !kernel_present() {
            return;
        }
        let sheet = rect_sheet([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 20.0, 20.0);
        let corners = [[-5.0, -5.0, 0.0], [5.0, -5.0, 0.0], [5.0, 5.0, 0.0], [-5.0, 5.0, 0.0], [-5.0, -5.0, 0.0]];
        let square = NurbsCurve::through(&corners, 1, false, None, None).unwrap();
        let (window, faces) = sheet.recess(&square, 3.0, 0.0, 0.0, true, Some(0.01)).unwrap();
        assert_eq!(faces, (1, 0, 4, 1));
        assert_eq!(window.faces().unwrap(), 6);
    }

    #[test]
    fn trim_by_curve_and_join_refuse_by_name() {
        if !kernel_present() {
            return;
        }
        let sheet = rect_sheet([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 20.0, 20.0);
        let ring = exact_circle([0.0; 3], 5.0);
        let far = message(sheet.trim_by_curve(&exact_circle([100.0, 0.0, 0.0], 5.0), TrimKeep::Inside, None, Some(0.05)));
        assert!(far.starts_with("trim_by_curve: ") && far.contains("nothing of the sheet lies inside"), "{far}");
        let zero = message(sheet.split_by_curve(&ring, Some([0.0; 3]), Some(0.05)));
        assert!(zero.starts_with("split_by_curve: ") && zero.contains("direction is zero"), "{zero}");
        assert!(message(Solid::join_sheets(&[], None)).starts_with("join_sheets: no sheets"));
        let neg = message(Solid::join_sheets(&[&sheet], Some(-1.0)));
        assert!(neg.starts_with("join_sheets: ") && neg.contains("tolerance"), "{neg}");
    }

    /// The 20 x 20 square in z = 0 facing +z with a round hole of radius 5 about (1, -2), and
    /// the indices of the hole's rim edges.
    fn holed_sheet() -> (Solid, Vec<u32>) {
        let sheet = rect_sheet([0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 20.0, 20.0);
        let holed = sheet.trim_by_curve(&exact_circle([1.0, -2.0, 0.0], 5.0), TrimKeep::Outside, Some([0.0, 0.0, -1.0]), Some(0.01)).unwrap();
        let rim: Vec<u32> = holed
            .edges()
            .unwrap()
            .iter()
            .filter(|e| e.faces.len() == 1 && e.segments.iter().all(|[a, _]| ((a[0] - 1.0).hypot(a[1] + 2.0) - 5.0).abs() < 1e-6))
            .map(|e| e.index)
            .collect();
        assert!(!rim.is_empty());
        (holed, rim)
    }

    #[test]
    fn a_flange_turns_a_hole_under_and_carries_it_inward() {
        if !kernel_present() {
            return;
        }
        let pi = std::f64::consts::PI;
        let (holed, rim) = holed_sheet();
        let under = seg([0.0; 3], [0.0, -3.0, 0.0]);
        // Turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet.
        let wall = holed.flange(&rim, &under, Some(1e-3), false).unwrap();
        assert_eq!(wall.faces().unwrap() as usize, rim.len());
        assert!(wall.sheet_error().unwrap() <= 1e-3, "{:?}", wall.sheet_error());
        near(area_of(&wall), 2.0 * pi * 5.0 * 3.0, 0.05, "flange area");
        let (lo, hi) = wall.bounds().unwrap();
        near(lo[2], -3.0, 1e-3, "flange bottom");
        near(hi[2], 0.0, 1e-3, "flange top");
        near(lo[0], 1.0 - 5.0, 1e-2, "flange min x");
        near(hi[0], 1.0 + 5.0, 1e-2, "flange max x");
        // Carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3.
        let ring = holed.flange(&rim, &seg([0.0; 3], [2.0, 0.0, 0.0]), Some(1e-3), false).unwrap();
        near(area_of(&ring), pi * (25.0 - 9.0), 0.05, "annulus area");
        // Joined, the sheet's faces come first and the flange is sewn on.
        let joined = holed.flange(&rim, &under, Some(1e-3), true).unwrap();
        assert_eq!(joined.faces().unwrap() as usize, holed.faces().unwrap() as usize + rim.len());
        near(area_of(&joined), area_of(&holed) + 2.0 * pi * 5.0 * 3.0, 0.05, "joined area");
        // The rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange.
        let on_rim: Vec<Edge> = joined
            .edges()
            .unwrap()
            .into_iter()
            .filter(|e| e.segments.iter().all(|[a, _]| ((a[0] - 1.0).hypot(a[1] + 2.0) - 5.0).abs() < 1e-3 && a[2].abs() < 1e-6))
            .collect();
        assert!(!on_rim.is_empty());
        for e in &on_rim {
            let mut faces = e.faces.clone();
            faces.sort_unstable();
            assert_eq!(faces, vec![0, 1], "{e:?}");
        }
    }

    #[test]
    fn a_liner_runs_a_hole_down_to_a_tilted_floor() {
        if !kernel_present() {
            return;
        }
        let (holed, rim) = holed_sheet();
        // The floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
        // 6.9 on average round a hole centred at x = 1.
        let sides = [
            seg([-20.0, -20.0, -9.0], [20.0, -20.0, -5.0]),
            seg([20.0, -20.0, -5.0], [20.0, 20.0, -5.0]),
            seg([20.0, 20.0, -5.0], [-20.0, 20.0, -9.0]),
            seg([-20.0, 20.0, -9.0], [-20.0, -20.0, -9.0]),
        ];
        let floor = Solid::edge_surface(&[&sides[0], &sides[1], &sides[2], &sides[3]], None).unwrap();
        let wall = holed.extrude_to(&rim, [0.0, 0.0, -1.0], &floor, Some(1e-3), false).unwrap();
        assert_eq!(wall.faces().unwrap() as usize, rim.len());
        assert!(wall.sheet_error().unwrap() <= 1e-3, "{:?}", wall.sheet_error());
        near(area_of(&wall), 2.0 * std::f64::consts::PI * 5.0 * 6.9, 0.05, "liner area");
        let (lo, hi) = wall.bounds().unwrap();
        near(lo[2], -7.0 + 0.1 * (1.0 - 5.0), 1e-2, "liner bottom");
        near(hi[2], 0.0, 1e-6, "liner top");
        let joined = holed.extrude_to(&rim, [0.0, 0.0, -1.0], &floor, Some(1e-3), true).unwrap();
        assert_eq!(joined.faces().unwrap() as usize, holed.faces().unwrap() as usize + rim.len());
        assert!(joined.step_text(None, Unit::Millimetre).unwrap().contains("SURFACE_OF_LINEAR_EXTRUSION"));
    }

    #[test]
    fn flange_and_extrude_to_refuse_by_name() {
        if !kernel_present() {
            return;
        }
        let (holed, rim) = holed_sheet();
        let under = seg([0.0; 3], [0.0, -3.0, 0.0]);
        let off = message(holed.flange(&rim, &seg([1.0, 0.0, 0.0], [1.0, -3.0, 0.0]), Some(1e-3), true));
        assert!(off.starts_with("flange: the section starts at"), "{off}");
        let none = message(holed.flange(&[], &under, Some(1e-3), true));
        assert!(none.starts_with("flange: no edges given"), "{none}");
        let range = message(holed.flange(&[999], &under, Some(1e-3), true));
        assert!(range.starts_with("flange: no edge 999"), "{range}");
        let cube = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let two = message(cube.flange(&[0], &under, Some(1e-3), true));
        assert!(two.starts_with("flange: edge 0 borders 2 faces"), "{two}");
        let floor = rect_sheet([0.0, 0.0, -7.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], 40.0, 40.0);
        let miss = message(holed.extrude_to(&rim, [0.0, 0.0, 1.0], &floor, Some(1e-3), true));
        assert!(miss.starts_with("extrude_to: edge ") && miss.contains("misses the target"), "{miss}");
        let zero = message(holed.extrude_to(&rim, [0.0; 3], &floor, Some(1e-3), true));
        assert!(zero.starts_with("extrude_to: the direction has no length"), "{zero}");
    }

    #[test]
    fn continuity_match_and_blend() {
        if !kernel_present() {
            return;
        }
        let a = Solid::loft_curves(&[&seg([-1.0, 0.0, 0.0], [0.0; 3]), &seg([-1.0, 1.0, 0.0], [0.0, 1.0, 0.0])], 1, false, false).unwrap();
        let b = Solid::loft_curves(&[&seg([0.0; 3], [0.0, 0.0, 1.0]), &seg([0.0, 1.0, 0.0], [0.0, 1.0, 1.0])], 1, false, false).unwrap();
        let r = a.continuity(SheetSide::U1, &b, SheetSide::U0, 0, 0, 32).unwrap();
        assert!(r.gap <= 1e-12 && (r.angle - std::f64::consts::FRAC_PI_2).abs() <= 1e-9 && r.samples >= 33, "{r:?}");
        // A gap that grows along the side: where it is largest is the far end, and that is
        // reported as the gap's place, not the angle's.
        let tilted = Solid::loft_curves(&[&seg([0.0; 3], [0.0, 0.0, 1.0]), &seg([0.0, 1.0, 0.5], [0.0, 1.0, 1.5])], 1, false, false).unwrap();
        let t = a.continuity(SheetSide::U1, &tilted, SheetSide::U0, 0, 0, 32).unwrap();
        near(t.gap, 0.5 / 1.25f64.sqrt(), 1e-9, "tilted gap (the distance to the other side)");
        near(t.gap_at[1], 1.0, 1e-9, "the gap is largest at y = 1");
        assert!(t.gap_at[2].abs() <= 1e-9 && t.gap_at[0].abs() <= 1e-9, "{t:?}");
        let m = a.matched(SheetSide::U1, &b, SheetSide::U0, 1, 0, 0).unwrap();
        let r = m.continuity(SheetSide::U1, &b, SheetSide::U0, 0, 0, 64).unwrap();
        assert!(r.gap <= 1e-10 && r.angle <= 1e-8, "{r:?}");
        let blend = Solid::blend_sides(&a, SheetSide::U0, &b, SheetSide::U1, 2, 1.0, 0, 0).unwrap();
        let r = blend.continuity(SheetSide::V0, &a, SheetSide::U0, 0, 0, 64).unwrap();
        assert!(r.gap <= 1e-10 && r.angle <= 1e-8 && r.curvature <= 1e-6, "{r:?}");
        assert!(message(a.matched(SheetSide::U1, &b, SheetSide::U0, 3, 0, 0)).starts_with("match_side: "));
    }

    #[test]
    fn n_sided_patch_fills_a_pentagon_of_strips() {
        if !kernel_present() {
            return;
        }
        // Five flat strips round a pentagon in z = 0, each lofted from a side outward: the hole's
        // side is each loft's v0. Given every way the wrapper takes a boundary.
        let corners: Vec<[f64; 3]> = (0..5)
            .map(|k| {
                let a = 2.0 * std::f64::consts::PI * f64::from(k) / 5.0 + 0.1 * (3.0 * f64::from(k)).sin();
                [a.cos(), a.sin(), 0.0]
            })
            .collect();
        let out = |p: [f64; 3]| [1.6 * p[0], 1.6 * p[1], 0.0];
        let strips: Vec<Solid> = (0..5)
            .map(|i| {
                let (a, b) = (corners[i], corners[(i + 1) % 5]);
                Solid::loft_curves(&[&seg(a, b), &seg(out(a), out(b))], 1, false, false).unwrap()
            })
            .collect();
        let edge = seg(corners[3], corners[4]);
        let boundaries = [
            PatchBoundary::side(&strips[0], SheetSide::V0),
            PatchBoundary::side(&strips[1], SheetSide::V0).level(1),
            PatchBoundary::side(&strips[2], SheetSide::V0).range(1.0, 0.0),
            PatchBoundary::from(&edge),
            PatchBoundary::side(&strips[4], SheetSide::V0).level(2).face(0),
        ];
        let fill = Solid::n_sided_patch(&boundaries, 1.0, Some(1e-6)).unwrap();
        let r = *fill.patch_report().expect("a patch reports how it meets");
        assert!(fill.faces().unwrap() == 5 && r.faces == 5, "{r:?}");
        assert!(r.boundary.gap <= 1e-9 && r.boundary.angle <= 1e-6 && r.internal.angle <= 1e-6 && r.corner_angle <= 1e-9, "{r:?}");
        assert!(r.boundary.samples > 0 && r.internal.samples > 0);
        assert!(fill.sheet_error().is_none());
        // Face 0 meets strip 0's second half along its v0 side, face 4 the first half along u1.
        for (face, side) in [(0, SheetSide::V0), (4, SheetSide::U1)] {
            let k = fill.continuity(side, &strips[0], SheetSide::V0, face, 0, 64).unwrap();
            assert!(k.gap <= 1e-9 && k.angle <= 1e-6, "{face}: {k:?}");
        }
        // Into the ring: watertight round the hole but where the curve stood in for strip 3.
        let (_, report) = Solid::join_sheets(&[&strips[0], &strips[1], &strips[2], &strips[4], &fill], Some(1e-6)).unwrap();
        // Naked: the four strips' outer sides, the two radial sides beside the gap, the curve's two halves.
        assert!(report.refused == 0 && report.naked_after == 4 + 2 + 2, "{report:?}");
        assert!(message(Solid::n_sided_patch(&boundaries[..2], 1.0, Some(0.01))).starts_with("n_sided_patch: "));
        // A level the kernel refuses is passed on as given, not made G2.
        let bad: Vec<PatchBoundary> = strips.iter().map(|s| PatchBoundary::side(s, SheetSide::V0).level(3)).collect();
        let level = message(Solid::n_sided_patch(&bad, 1.0, Some(1e-6)));
        assert!(level.starts_with("n_sided_patch: ") && level.contains("level 3 is not 0, 1 or 2"), "{level}");
        // Every boundary a sheet's side: the curve's place taken by strip 3, the same five faces.
        let whole: Vec<PatchBoundary> = strips.iter().map(|s| PatchBoundary::side(s, SheetSide::V0)).collect();
        let all = Solid::n_sided_patch(&whole, 1.0, Some(1e-6)).unwrap();
        assert_eq!(all.faces().unwrap(), 5);
        assert!(all.patch_report().unwrap().boundary.angle <= 1e-6);
    }

    #[test]
    fn fillet_surfaces_rolls_a_ball_between_two_sheets() {
        if !kernel_present() {
            return;
        }
        let floor = Solid::loft_curves(&[&seg([0.0; 3], [4.0, 0.0, 0.0]), &seg([0.0, 3.0, 0.0], [4.0, 3.0, 0.0])], 1, false, false).unwrap();
        let wall = Solid::loft_curves(&[&seg([0.0; 3], [0.0, 3.0, 0.0]), &seg([0.0, 0.0, 4.0], [0.0, 3.0, 4.0])], 1, false, false).unwrap();
        let mut found = None;
        for (fa, fb) in [(false, false), (true, false), (false, true), (true, true)] {
            let Ok((sheet, ra, rb)) = Solid::fillet_surfaces(&floor, &wall, 1.0, None, fa, fb, Some(1e-4), 0, 0) else { continue };
            let p = ra.point(ra.domain().unwrap().0).unwrap();
            if p[0] > 0.0 && p[2].abs() <= 1e-9 {
                found = Some((sheet, ra, rb));
                break;
            }
        }
        let (sheet, ra, rb) = found.expect("one side of each sheet rolls the ball into the corner");
        assert_eq!(sheet.faces().unwrap(), 1);
        let e = sheet.sheet_error().expect("a fillet sheet reports its fit");
        assert!((0.0..=1e-4).contains(&e), "{e}");
        assert!(sheet.patch_report().is_none());
        // The contact on the floor is a radius out from the wall, the one on the wall a radius up.
        near(ra.point(ra.domain().unwrap().0).unwrap()[0], 1.0, 1e-4, "contact on the floor");
        near(rb.point(rb.domain().unwrap().0).unwrap()[2], 1.0, 1e-4, "contact on the wall");
        // The rails are the caller's: they outlive both sheets and the fillet.
        drop(sheet);
        drop(floor);
        drop(wall);
        near(ra.point(ra.domain().unwrap().0).unwrap()[0], 1.0, 1e-4, "a rail read after its sheets are gone");
        near(rb.point(rb.domain().unwrap().0).unwrap()[2], 1.0, 1e-4, "the other rail too");
        let flat = Solid::loft_curves(&[&seg([0.0; 3], [4.0, 0.0, 0.0]), &seg([0.0, 3.0, 0.0], [4.0, 3.0, 0.0])], 1, false, false).unwrap();
        let upright = Solid::loft_curves(&[&seg([0.0; 3], [0.0, 3.0, 0.0]), &seg([0.0, 0.0, 4.0], [0.0, 3.0, 4.0])], 1, false, false).unwrap();
        assert!(message(Solid::fillet_surfaces(&flat, &upright, 0.0, None, false, false, Some(1e-3), 0, 0)).starts_with("fillet_surfaces: "));
    }

    /// Two bicubic patches -- a fender's top and a door's side -- sharing the crease row, joined.
    fn fender_and_door() -> Solid {
        let length = 400.0;
        let (mut a_rows, mut b_rows) = (Vec::new(), Vec::new());
        for y in [0.0, length / 3.0, 2.0 * length / 3.0, length] {
            let s = (std::f64::consts::PI * y / length).sin();
            let c = [150.0 + 8.0 * s, y, 6.0 * s];
            a_rows.push(NurbsCurve::new(&[[0.0, y, 10.0], [50.0, y, 14.0], [100.0, y, 12.0], c], 3, None, None).unwrap());
            b_rows.push(NurbsCurve::new(&[c, [c[0] + 14.0, y, c[2] - 60.0], [c[0] + 10.0, y, c[2] - 130.0], [c[0] - 4.0, y, c[2] - 200.0]], 3, None, None).unwrap());
        }
        let ar: Vec<&NurbsCurve> = a_rows.iter().collect();
        let br: Vec<&NurbsCurve> = b_rows.iter().collect();
        let a = Solid::loft_curves(&ar, 3, true, false).unwrap();
        let b = Solid::loft_curves(&br, 3, true, false).unwrap();
        let (shell, report) = Solid::join_sheets(&[&a, &b], Some(1e-6)).unwrap();
        assert_eq!(report.sewn, 1);
        shell
    }

    #[test]
    fn fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius() {
        if !kernel_present() {
            return;
        }
        let shell = fender_and_door();
        let crease: Vec<u32> = shell.edges().unwrap().into_iter().filter(|e| e.faces.len() == 2).map(|e| e.index).collect();
        assert_eq!(crease.len(), 1);
        assert_eq!(shell.edges().unwrap()[crease[0] as usize].kind, "nurbs");
        let constant = shell.fillet(&crease, 12.0, 1e-3).unwrap();
        let varying = shell.fillet_varying(&crease, 8.0, Some(20.0), 1e-3).unwrap();
        assert_eq!((constant.faces().unwrap(), varying.faces().unwrap()), (3, 3));
        // The fillet cuts the corner off: less area than the sharp shell, and more taken by the
        // larger ball on average (8 to 20 against 12 all along).
        assert!(area_of(&varying) < area_of(&constant) && area_of(&constant) < area_of(&shell));
        // A radius_end of none, or equal to the radius, is the constant fillet.
        for end in [None, Some(12.0)] {
            let same = shell.fillet_varying(&crease, 12.0, end, 1e-3).unwrap();
            assert_eq!(area_of(&same), area_of(&constant));
        }
        let cube = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let refused = message(cube.fillet_varying(&[0], 1.0, Some(2.0), FILLET_TOLERANCE));
        assert!(refused.contains("a varying radius rounds only spline edges"), "{refused}");
    }

    // ---- the R-tree (rtree plan 3): Python's test_rtree_*, trimmed to the marshalling ----

    fn cell(x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64) -> Aabb {
        Aabb::new([x0, y0, z0], [x1, y1, z1])
    }

    fn grid() -> Vec<(u32, Aabb)> {
        let mut cells = Vec::new();
        for i in 0..10 {
            for j in 0..10 {
                for k in 0..10 {
                    let (x, y, z) = (i as f64, j as f64, k as f64);
                    cells.push((100 * i + 10 * j + k, cell(x, y, z, x + 1.0, y + 1.0, z + 1.0)));
                }
            }
        }
        cells
    }

    fn pairs_sorted(pairs: &[RTreePair]) -> bool {
        pairs.windows(2).all(|w| (w[0].a, w[0].b) <= (w[1].a, w[1].b))
    }

    #[test]
    fn an_rtree_grid_packed_or_grown_answers_alike() {
        if !kernel_present() {
            return;
        }
        let cells = grid();
        let packed = RTree::from_boxes(&cells).unwrap();
        let mut grown = RTree::new().unwrap();
        for (id, b) in cells.iter().rev() {
            grown.insert(*id, b).unwrap();
        }
        let corner: Vec<u32> = cells.iter().map(|c| c.0).filter(|id| id / 100 <= 2 && id / 10 % 10 <= 2 && id % 10 <= 2).collect();
        let mut answers = Vec::new();
        for (name, tree) in [("from_boxes", &packed), ("insert", &grown)] {
            assert_eq!(tree.len(), 1000, "{name}");
            assert!(!tree.is_empty(), "{name}");
            assert_eq!(tree.bounds().unwrap(), Some(cell(0.0, 0.0, 0.0, 10.0, 10.0, 10.0)), "{name}");
            assert_eq!(tree.search(&cell(0.0, 0.0, 0.0, 2.0, 2.0, 2.0)).unwrap(), corner, "{name}");
            let near1 = tree.nearest([-1.0; 3], 1).unwrap();
            assert_eq!(near1.len(), 1, "{name}");
            assert_eq!(near1[0].id, 0, "{name}");
            near(near1[0].distance, 3f64.sqrt(), 1e-12, name);
            assert_eq!(tree.within([0.0; 3], 0.0).unwrap(), vec![RTreeHit { id: 0, distance: 0.0 }], "{name}");
            let four: Vec<u32> = tree.within([-1.0; 3], 2.5).unwrap().iter().map(|h| h.id).collect();
            assert_eq!(four, [0, 1, 10, 100], "{name}");
            let pairs = tree.self_overlaps(0.0).unwrap();
            assert_eq!(pairs.len(), (28 * 28 * 28 - 1000) / 2, "{name}");
            assert!(pairs.iter().all(|p| p.a < p.b) && pairs_sorted(&pairs), "{name}: a pair out of order");
            assert_eq!(tree.self_overlaps(0.5).unwrap(), pairs, "{name}: unit gaps paired at slack 0.5");
            answers.push(pairs);
        }
        assert_eq!(answers[0], answers[1], "the packed and the grown trees disagree");
    }

    #[test]
    fn rtree_overlaps_two_trees_and_one_tree_twice() {
        if !kernel_present() {
            return;
        }
        let packed = RTree::from_boxes(&grid()).unwrap();
        let one = RTree::from_boxes(&[(7, cell(4.5, 4.5, 4.5, 5.5, 5.5, 5.5))]).unwrap();
        let ids = [444, 445, 454, 455, 544, 545, 554, 555];
        let want: Vec<RTreePair> = ids.iter().map(|&a| RTreePair { a, b: 7 }).collect();
        let back: Vec<RTreePair> = ids.iter().map(|&b| RTreePair { a: 7, b }).collect();
        assert_eq!(packed.overlaps(&one, 0.0).unwrap(), want);
        assert_eq!(one.overlaps(&packed, 0.0).unwrap(), back);
        let twice = packed.overlaps(&packed, 0.0).unwrap();
        assert_eq!(twice.len(), 1000 + 2 * 10476);
        assert!(pairs_sorted(&twice));
    }

    #[test]
    fn rtree_points_insert_and_remove() {
        if !kernel_present() {
            return;
        }
        let points = RTree::from_points(&[[0.0, 0.0, 0.0], [5.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 3.0, 0.0]]).unwrap();
        assert_eq!(points.search(&cell(-0.1, -0.1, -0.1, 1.1, 0.1, 0.1)).unwrap(), [0, 2], "ids are the indices");
        assert_eq!(
            points.nearest([4.0, 0.0, 0.0], 2).unwrap(),
            [RTreeHit { id: 1, distance: 1.0 }, RTreeHit { id: 2, distance: 3.0 }]
        );
        let mut tree = RTree::new().unwrap();
        let unit = cell(3.0, 3.0, 3.0, 4.0, 4.0, 4.0);
        tree.insert(7, &unit).unwrap();
        tree.insert(7, &unit).unwrap();
        assert_eq!(tree.search(&unit).unwrap(), [7, 7], "one (id, box) twice is two entries");
        assert_eq!([tree.remove(7, &unit).unwrap(), tree.remove(7, &unit).unwrap(), tree.remove(7, &unit).unwrap()], [true, true, false]);
        tree.insert(7, &unit).unwrap();
        assert!(!tree.remove(8, &unit).unwrap(), "another id took the entry out");
        assert!(!tree.remove(7, &cell(3.0, 3.0, 3.0, 4.0, 4.0, 4.5)).unwrap(), "another box took the entry out");
        let point = [1.0, 2.0, 3.0];
        tree.insert_point(9, point).unwrap();
        assert_eq!(tree.len(), 2);
        assert_eq!(tree.bounds().unwrap(), Some(Aabb::new(point, [4.0; 3])));
        assert!(tree.remove_point(9, point).unwrap() && tree.remove(7, &unit).unwrap(), "the point or the box stayed");
        assert_eq!((tree.len(), tree.is_empty(), tree.bounds().unwrap()), (0, true, None), "emptied");
        tree.insert_point(u32::MAX, point).unwrap();
        assert_eq!(tree.search(&cell(0.0, 0.0, 0.0, 5.0, 5.0, 5.0)).unwrap(), [u32::MAX], "the largest id came back whole");
        assert!(tree.remove_point(u32::MAX, point).unwrap());
    }

    #[test]
    fn closest_points_and_k_neighbors_match_brute_force() {
        if !kernel_present() {
            return;
        }
        let mut state: u64 = 5;
        let mut next = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (state >> 11) as f64 / (1u64 << 53) as f64
        };
        let hay: Vec<[f64; 3]> = (0..30).map(|_| [10.0 * next(), 10.0 * next(), 10.0 * next()]).collect();
        let needles: Vec<[f64; 3]> = (0..5).map(|_| [10.0 * next(), 10.0 * next(), 10.0 * next()]).collect();
        let by_distance = |q: [f64; 3]| {
            let mut order: Vec<usize> = (0..hay.len()).collect();
            order.sort_by(|&x, &y| dist(hay[x], q).total_cmp(&dist(hay[y], q)).then(x.cmp(&y)));
            order
        };
        let close = closest_points(&hay, &needles, 3.0).unwrap();
        let knn = k_neighbors(&hay, &needles, 4).unwrap();
        assert_eq!((close.len(), knn.len()), (5, 5));
        let (mut some, mut all) = (false, true);
        for (n, &q) in needles.iter().enumerate() {
            let order = by_distance(q);
            let in_limit: Vec<usize> = order.iter().copied().filter(|&i| dist(hay[i], q) <= 3.0).collect();
            assert_eq!(close[n], in_limit, "closest points, needle {n}");
            assert_eq!(knn[n], order[..4], "k neighbors, needle {n}");
            some |= !in_limit.is_empty();
            all &= in_limit.len() == hay.len();
        }
        assert!(some && !all, "the limit chose nothing or everything");
        let every = k_neighbors(&hay, &needles[..2], 500).unwrap();
        assert_eq!(every.len(), 2);
        assert_eq!(every[1], by_distance(needles[1]), "k over the hay count is every point");
        assert_eq!(k_neighbors(&[], &needles[..2], 3).unwrap(), [Vec::<usize>::new(), Vec::new()], "an empty hay");
    }

    #[test]
    fn rtree_refusals_name_their_call() {
        if !kernel_present() {
            return;
        }
        let (nan, inf) = (f64::NAN, f64::INFINITY);
        let mut tree = RTree::new().unwrap();
        for bad in [cell(0.0, 0.0, 0.0, nan, 1.0, 1.0), cell(1.0, 0.0, 0.0, 0.0, 1.0, 1.0)] {
            let said = message(tree.insert(1, &bad));
            assert!(said.starts_with("rtree_insert: ") && said.ends_with("is not a box"), "{said}");
        }
        let said = message(tree.insert_point(1, [inf, 0.0, 0.0]));
        assert!(said.starts_with("rtree_insert_point: ") && said.ends_with("is not finite"), "{said}");
        assert_eq!(tree.len(), 0, "a refused insert changed the tree");
        assert!(message(tree.remove(1, &cell(1.0, 0.0, 0.0, 0.0, 1.0, 1.0))).starts_with("rtree_remove: "));
        assert!(!tree.remove(1, &cell(0.0, 0.0, 0.0, 1.0, 1.0, 1.0)).unwrap(), "absent right after a refusal");
        assert!(message(tree.search(&cell(0.0, 0.0, 0.0, nan, 1.0, 1.0))).starts_with("rtree_search: "));
        let said = message(tree.within([nan, 0.0, 0.0], 1.0));
        assert!(said.starts_with("rtree_within: ") && said.ends_with("is not finite"), "{said}");
        let said = message(tree.nearest([nan, 0.0, 0.0], 1));
        assert!(said.starts_with("rtree_nearest: ") && said.ends_with("is not finite"), "{said}");
        assert_eq!(message(tree.within([0.0; 3], -1.0)), "rtree_within: radius -1 is not a distance");
        assert_eq!(message(tree.self_overlaps(nan)), "rtree_self_overlaps: slack NaN is not a distance");
        assert!(message(tree.overlaps(&tree, -0.5)).starts_with("rtree_overlaps: "));
        assert_eq!(message(tree.nearest([0.0; 3], 1_000_001)), "rtree_nearest: k 1000001 is not at most 1000000");
        let said = message(RTree::from_boxes(&[(1, cell(0.0, 0.0, 0.0, 1.0, 1.0, 1.0)), (2, cell(2.0, 0.0, 0.0, 1.0, 1.0, 1.0))]));
        assert!(said.starts_with("rtree_from_boxes: entry 1"), "{said}");
        assert_eq!(message(RTree::from_points(&[[0.0; 3], [0.0, nan, 0.0]])), "rtree_from_points: point 1 is not finite");
        let origin = [[0.0; 3]];
        assert_eq!(message(closest_points(&origin, &origin, -1.0)), "closest_points: limit -1 is not a distance");
        assert_eq!(
            message(closest_points(&[[0.0; 3], [nan, 0.0, 0.0]], &[[inf, 0.0, 0.0]], -1.0)),
            "closest_points: limit -1 is not a distance",
            "the limit first"
        );
        assert_eq!(message(closest_points(&origin, &[[nan, 0.0, 0.0]], 1.0)), "closest_points: needle point 0 is not finite");
        assert_eq!(
            message(closest_points(&[[0.0; 3], [0.0, 0.0, nan]], &[[nan, 0.0, 0.0]], 1.0)),
            "closest_points: hay point 1 is not finite",
            "the hay before the needles"
        );
        assert_eq!(
            message(k_neighbors(&[[0.0; 3], [inf, 0.0, 0.0]], &origin, 1_000_001)),
            "k_neighbors: hay point 1 is not finite",
            "the points before k"
        );
        assert_eq!(message(k_neighbors(&origin, &origin, 1_000_001)), "k_neighbors: k 1000001 is not at most 1000000");
    }

    #[test]
    fn an_empty_rtree_answers_nothing() {
        if !kernel_present() {
            return;
        }
        let other = RTree::from_boxes(&grid()).unwrap();
        let empty = RTree::new().unwrap();
        assert_eq!((empty.len(), empty.is_empty(), empty.bounds().unwrap()), (0, true, None));
        assert!(empty.search(&cell(0.0, 0.0, 0.0, 1.0, 1.0, 1.0)).unwrap().is_empty());
        assert!(empty.within([0.0; 3], 10.0).unwrap().is_empty());
        assert!(empty.nearest([0.0; 3], 3).unwrap().is_empty());
        assert!(empty.self_overlaps(0.0).unwrap().is_empty());
        assert!(empty.overlaps(&other, 0.0).unwrap().is_empty());
        assert!(other.overlaps(&empty, 0.0).unwrap().is_empty());
        let empty_too = RTree::from_boxes(&[]).unwrap();
        assert!(empty_too.is_empty() && RTree::from_points(&[]).unwrap().is_empty());
        assert!(format!("{empty:?}").starts_with("RTree("), "{empty:?}");
        // Send, not Sync: a tree may move to another thread.
        let moved = std::thread::spawn(move || empty.len()).join().unwrap();
        assert_eq!(moved, 0);
    }

    // ---- the interpolator, circumscribed polygon, merge and regions (wrappers plan,
    // 2026-10-27): Python's test_interpolator_*, test_circumscribed_*, test_merge_*, trimmed to
    // the marshalling ----

    const SQUARES: [f64; 5] = [0.0, 1.0, 4.0, 9.0, 16.0];
    const MODES: [InterpolatorMode; 5] = [
        InterpolatorMode::Nearest,
        InterpolatorMode::Linear,
        InterpolatorMode::Cosine,
        InterpolatorMode::Cubic,
        InterpolatorMode::CatmullRom,
    ];

    fn one(v: Vec<f64>) -> f64 {
        assert_eq!(v.len(), 1, "a dimension-1 value: {v:?}");
        v[0]
    }

    #[test]
    fn interpolator_modes_are_the_c_constants() {
        let codes: Vec<u32> = MODES.iter().map(|&m| m as u32).collect();
        assert_eq!(
            codes,
            [
                sys::CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST,
                sys::CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR,
                sys::CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE,
                sys::CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC,
                sys::CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM,
            ]
        );
        assert_eq!(codes, [0, 1, 2, 3, 4]);
        assert_eq!(InterpolatorMode::default(), InterpolatorMode::Linear);
    }

    #[test]
    fn interpolator_closed_forms_on_the_squares() {
        if !kernel_present() {
            return;
        }
        let sq = Interpolator::new(&SQUARES, false).unwrap();
        assert_eq!((sq.len(), sq.is_empty(), sq.dimension(), sq.cyclic()), (5, false, 1, false));
        for mode in MODES {
            for (k, &y) in SQUARES.iter().enumerate() {
                near(one(sq.at(k as f64, mode).unwrap()), y, 1e-12, &format!("{mode:?} at {k}"));
            }
            near(one(sq.at(-2.0, mode).unwrap()), 0.0, 1e-12, &format!("{mode:?} clamped low"));
            near(one(sq.at(7.0, mode).unwrap()), 16.0, 1e-12, &format!("{mode:?} clamped high"));
        }
        assert_eq!(one(sq.nearest(1.5).unwrap()), 4.0);
        assert_eq!(one(sq.nearest(1.49).unwrap()), 1.0);
        near(one(sq.linear(1.5).unwrap()), 2.5, 1e-12, "linear");
        near(one(sq.cosine(1.5).unwrap()), 2.5, 1e-12, "cosine");
        near(one(sq.cosine(1.25).unwrap()), 1.0 + 3.0 * (1.0 - (std::f64::consts::PI / 4.0).cos()) / 2.0, 1e-12, "cosine at a quarter");
        near(one(sq.cubic(1.5).unwrap()), 2.0, 1e-12, "cubic");
        near(one(sq.catmull_rom(1.5).unwrap()), 2.25, 1e-12, "catmull-rom");
        assert_eq!(sq.at(1.5, InterpolatorMode::default()).unwrap(), sq.linear(1.5).unwrap(), "linear by default");
        let ring = Interpolator::new(&SQUARES, true).unwrap();
        assert!(ring.cyclic());
        near(one(ring.catmull_rom(5.0).unwrap()), one(ring.catmull_rom(0.0).unwrap()), 1e-12, "wrapped");
        near(one(ring.linear(-0.5).unwrap()), 8.0, 1e-12, "halfway from the last sample back to the first");
        assert!(format!("{ring:?}").starts_with("Interpolator(5 samples of 1, cyclic"), "{ring:?}");
    }

    #[test]
    fn interpolator_points_and_sample_is_a_loop_of_at() {
        if !kernel_present() {
            return;
        }
        let helix: Vec<[f64; 3]> = (0..9).map(|k| [(0.7 * k as f64).cos(), (0.7 * k as f64).sin(), 0.3 * k as f64]).collect();
        let h = Interpolator::rows(&helix, false).unwrap();
        assert_eq!((h.len(), h.dimension()), (9, 3));
        let two = h.at(2.0, InterpolatorMode::Linear).unwrap();
        near3([two[0], two[1], two[2]], helix[2], 1e-12, "sample 2");
        assert_eq!(h.catmull_rom(2.5).unwrap().len(), 3);
        let ts: Vec<f64> = (0..50).map(|k| -1.0 + 10.0 * k as f64 / 49.0).collect();
        for mode in MODES {
            let looped: Vec<Vec<f64>> = ts.iter().map(|&t| h.at(t, mode).unwrap()).collect();
            assert_eq!(h.sample(&ts, mode).unwrap(), looped, "{mode:?}");
        }
        assert!(h.sample(&[], InterpolatorMode::Linear).unwrap().is_empty());
        let corners = vec![vec![0.0, 0.0], vec![1.0, 0.0], vec![1.0, 1.0], vec![0.0, 1.0]];
        let square = Interpolator::rows(&corners, true).unwrap();
        let back = square.linear(-0.5).unwrap();
        assert_eq!(back.len(), 2);
        near(back[0], 0.0, 1e-12, "x");
        near(back[1], 0.5, 1e-12, "y");
        let both = square.sample(&[0.5, 1.5], InterpolatorMode::Linear).unwrap();
        assert_eq!(both.len(), 2);
        for (got, want) in both.iter().zip([[0.5, 0.0], [1.0, 0.5]]) {
            assert_eq!(got.len(), 2);
            near(got[0], want[0], 1e-12, "x");
            near(got[1], want[1], 1e-12, "y");
        }
        // Send and Sync: one interpolator read from two threads at once.
        let shared = std::sync::Arc::new(h);
        let other = std::sync::Arc::clone(&shared);
        let there = std::thread::spawn(move || other.cubic(3.25).unwrap()).join().unwrap();
        assert_eq!(there, shared.cubic(3.25).unwrap());
    }

    #[test]
    fn interpolator_refusals_name_their_call() {
        if !kernel_present() {
            return;
        }
        assert!(message(Interpolator::new(&[], false)).starts_with("interpolator_new: no samples"));
        assert!(message(Interpolator::rows::<[f64; 2]>(&[], false)).starts_with("interpolator_new: no samples"));
        assert!(message(Interpolator::new(&[0.0, 1.0, f64::NAN], false)).starts_with("interpolator_new: sample 2 is not finite"));
        let said = message(Interpolator::rows(&[vec![0.0, 1.0], vec![2.0, 3.0, 4.0]], false));
        assert_eq!(said, "interpolator: samples differ in length ([2, 3])");
        let sq = Interpolator::new(&SQUARES, false).unwrap();
        assert!(message(sq.linear(f64::NAN)).starts_with("interpolator_at: t NaN is not finite"));
        assert!(message(sq.sample(&[0.0, f64::INFINITY], InterpolatorMode::Linear)).starts_with("interpolator_sample: t 1 (inf) is not finite"));
        let many = vec![0.0; 1_000_001];
        assert!(message(sq.sample(&many, InterpolatorMode::Nearest)).starts_with("interpolator_sample: "));
    }

    #[test]
    fn circumscribed_polygon_touches_its_circle() {
        if !kernel_present() {
            return;
        }
        let (centre, r, n) = ([2.0, -1.0], 5.0, 6u32);
        let hex = Profile::circumscribed_polygon(centre, r, n, 0.3).unwrap();
        let loops = hex.polylines(DEFAULT_TOLERANCE).unwrap();
        assert_eq!(loops.len(), 1);
        let corners: Vec<[f64; 2]> = loops[0][..loops[0].len() - 1].iter().map(|p| [p[0] as f64, p[1] as f64]).collect();
        assert_eq!(corners.len(), n as usize);
        let from_centre = |x: f64, y: f64| (x - centre[0]).hypot(y - centre[1]);
        let step = std::f64::consts::PI / n as f64;
        for k in 0..corners.len() {
            let (a, b) = (corners[k], corners[(k + 1) % corners.len()]);
            near(from_centre(a[0], a[1]), r / step.cos(), 1e-5, &format!("corner {k}"));
            near(from_centre((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0), r, 1e-5, &format!("side {k}'s midpoint"));
        }
        let perimeter = 2.0 * n as f64 * r * step.tan();
        near(hex.length(0.0).unwrap().length, perimeter, 1e-9 * perimeter, "perimeter");
        assert!(message(Profile::circumscribed_polygon([0.0, 0.0], 10.0, 2, 0.0))
            .starts_with("profile_circumscribed_polygon: a polygon has at least 3 sides, not 2"));
    }

    const MERGE_TOLERANCE: f64 = 1e-6;

    fn cube_and_corner() -> (Solid, Solid) {
        let a = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        let b = a.translate(0.5, 0.5, 0.5).unwrap();
        let m = a.merge(&b, MERGE_TOLERANCE).unwrap();
        (a, m)
    }

    #[test]
    fn merge_of_two_cubes_at_a_corner_is_the_outside_and_three_cells() {
        if !kernel_present() {
            return;
        }
        let (_, m) = cube_and_corner();
        let faces = m.faces().unwrap();
        assert_eq!(faces, 18);
        let regions = m.regions().unwrap();
        assert_eq!(regions.iter().map(|r| r.index).collect::<Vec<_>>(), [0, 1, 2, 3]);
        assert!(!regions[0].finite && regions[1..].iter().all(|r| r.finite));
        assert!(regions.iter().all(|r| r.shells == 1));
        assert!(regions.iter().flat_map(|r| &r.sides).all(|s| s.sense == 1 || s.sense == -1));
        assert_eq!(regions.iter().map(|r| r.sides.len()).sum::<usize>(), 2 * faces as usize, "each face's two sides");
        for r in &regions {
            assert!(r.sides.windows(2).all(|w| w[0] < w[1]), "region {}'s sides out of order", r.index);
        }
        let covered: std::collections::BTreeSet<u32> = regions[1..].iter().flat_map(|r| r.sides.iter().map(|s| s.face)).collect();
        assert_eq!(covered.into_iter().collect::<Vec<_>>(), (0..faces).collect::<Vec<_>>());
        let volumes: Vec<(u32, f64)> = regions[1..].iter().map(|r| (r.index, m.region_solid(r.index).unwrap().mass(0.0).unwrap().volume)).collect();
        let mut sorted: Vec<f64> = volumes.iter().map(|v| v.1).collect();
        sorted.sort_by(f64::total_cmp);
        for (got, want) in sorted.iter().zip([0.125, 0.875, 0.875]) {
            near(*got, want, 1e-6, "a cell's volume");
        }
        let small = volumes.iter().find(|v| (v.1 - 0.125).abs() < 1e-6).unwrap().0;
        let overlap = &regions[small as usize];
        assert_eq!(overlap.sides.len(), 6);
        assert!(overlap.sides.iter().all(|s| s.sense == -1), "inside both, behind its walls");
        near3(overlap.bounds.lo, [0.0; 3], 1e-6, "the overlap's low corner");
        near3(overlap.bounds.hi, [0.5; 3], 1e-6, "the overlap's high corner");
        assert_eq!(m.regions().unwrap(), regions, "values, equal by value");
    }

    #[test]
    fn merge_of_a_ball_in_a_box_is_a_box_cell_with_a_void() {
        if !kernel_present() {
            return;
        }
        let m = Solid::cuboid(1.0, 1.0, 1.0).unwrap().merge(&Solid::sphere(0.3).unwrap(), MERGE_TOLERANCE).unwrap();
        let regions = m.regions().unwrap();
        assert_eq!(regions.len(), 3);
        let ball = 4.0 / 3.0 * std::f64::consts::PI * 0.3f64.powi(3);
        let volumes: Vec<f64> = (1..3).map(|i| m.region_solid(i).unwrap().mass(0.0).unwrap().volume).collect();
        let boxed = if volumes[0] > volumes[1] { 1 } else { 2 };
        near(volumes[boxed - 1], 1.0 - ball, 1e-6, "the box less the ball");
        near(volumes[2 - boxed], ball, 1e-6, "the ball");
        assert_eq!((regions[boxed].shells, regions[3 - boxed].shells), (2, 1));
    }

    #[test]
    fn a_merged_body_is_refused_by_the_manifold_verbs_and_its_cells_are_not() {
        if !kernel_present() {
            return;
        }
        let (a, m) = cube_and_corner();
        assert!(message(m.join(&a, MERGE_TOLERANCE))
            .starts_with("join: the join needs a manifold solid, and this one has edges of three or more faces"));
        assert!(message(m.mass(0.0)).starts_with("mass_properties: the mass needs a manifold solid"));
        assert_eq!(message(m.region_solid(0)), "region_solid: region 0 is the infinite region");
        assert_eq!(message(m.region_solid(4)), "region_solid: region 4 is not below 4");
        assert!(message(a.merge(&a, -1.0)).starts_with("merge: tolerance must be positive and finite"));
        let cell = m.region_solid(1).unwrap();
        assert!(cell.join(&a, MERGE_TOLERANCE).unwrap().faces().unwrap() > 0, "a cell is an ordinary solid again");
        let ordinary = a.regions().unwrap();
        assert_eq!(ordinary.len(), 2);
        assert!(ordinary[0].sides.iter().all(|s| s.sense == 1), "the outside is in front of every face");
        assert!(ordinary[1].sides.iter().all(|s| s.sense == -1), "the inside is behind them");
        assert_eq!(ordinary[0].sides.len(), 6);
    }

    // ---- identity and attributes (identity plan C3): Python's TestIdentity, trimmed to the
    // marshalling. Python's `join(merge=True)` is `merge_flush()` then `origins_through` here.

    /// A 10-cube centred on the origin and a pin through it (radius 2, along z, z -10..10),
    /// both tracked -- the kernel's oracle 2 cut.
    fn block_and_pin() -> (Solid, Solid) {
        let block = Solid::cuboid(10.0, 10.0, 10.0).unwrap().tracked().unwrap();
        let pin = Solid::cylinder(2.0, 20.0).unwrap().translate(0.0, 0.0, -10.0).unwrap().tracked().unwrap();
        (block, pin)
    }

    /// Face `f`'s outward normal's z, off its reference.
    fn nz(solid: &Solid, f: u32) -> f64 {
        solid.face_ref(f).unwrap()[6]
    }

    fn split_xy(solid: &Solid) -> Vec<Solid> {
        solid.split_by_plane(&Frame::xy([0.0; 3]), DEFAULT_TOLERANCE).unwrap()
    }

    #[test]
    fn identity_tracking_numbers_faces_and_edges_and_an_untracked_solid_has_no_ids() {
        if !kernel_present() {
            return;
        }
        let plain = Solid::cuboid(1.0, 2.0, 3.0).unwrap();
        assert!(!plain.is_tracked().unwrap());
        assert_eq!(plain.face_id(0).unwrap(), None);
        assert_eq!(plain.edge_id(0).unwrap(), None);
        assert_eq!(plain.face_origins(0).unwrap(), vec![]);
        let t = plain.tracked().unwrap();
        assert!(t.is_tracked().unwrap());
        assert_eq!(t.tracked().unwrap().face_id(5).unwrap(), Some(6));
        assert_eq!((0..6).map(|f| t.face_id(f).unwrap()).collect::<Vec<_>>(), (1..=6).map(Some).collect::<Vec<_>>());
        assert_eq!((0..12).map(|e| t.edge_id(e).unwrap()).collect::<Vec<_>>(), (1..=12).map(Some).collect::<Vec<_>>());
        assert_eq!((t.face_with_id(4).unwrap(), t.face_with_id(7).unwrap(), t.face_with_id(0).unwrap()), (Some(3), None, None));
        assert_eq!((t.edge_with_id(12).unwrap(), t.edge_with_id(13).unwrap()), (Some(11), None));
        assert_eq!(t.face_origins(2).unwrap(), vec![(0, 3)]);
        assert_eq!(t.edge_origins(11).unwrap(), vec![(0, 12)]);
        assert_eq!(message(t.face_id(6)), "face_id: face 6 of 6");
        assert_eq!(message(t.face_origins(6)), "face_origin_count: face 6 of 6");
        assert_eq!(message(t.edge_id(12)), "edge_id: edge 12 of 12");
    }

    #[test]
    fn identity_a_cuts_origins_and_history() {
        if !kernel_present() {
            return;
        }
        let (block, pin) = block_and_pin();
        let wall = (0..pin.faces().unwrap()).find(|&f| pin.face_kind(f).unwrap() == "cylinder").unwrap();
        let wall_id = pin.face_id(wall).unwrap().unwrap();
        let caps: Vec<Origin> =
            (0..pin.faces().unwrap()).filter(|&f| f != wall).map(|f| (1, pin.face_id(f).unwrap().unwrap())).collect();
        let cut = block.cut(&pin, DEFAULT_TOLERANCE).unwrap();
        let bore = (0..cut.faces().unwrap()).find(|&f| cut.face_kind(f).unwrap() == "cylinder").unwrap();
        assert_eq!(cut.face_origins(bore).unwrap(), vec![(1, wall_id)], "the bore came from the pin's wall");
        assert_eq!(cut.face_id(bore).unwrap(), Some(7), "renumbered: the wall's id is the box's");
        for f in (0..cut.faces().unwrap()).filter(|&f| f != bore) {
            assert_eq!(cut.face_origins(f).unwrap(), vec![(0, cut.face_id(f).unwrap().unwrap())], "the box's own");
        }
        let h = cut.history(&[&block, &pin]).unwrap();
        assert_eq!(h.kept, (1..=6).map(|k| ((0, k), k)).collect::<Vec<_>>(), "the box's six kept");
        assert_eq!(h.modified, vec![((1, wall_id), vec![7])], "the bore modified");
        assert_eq!(h.generated, Vec::<u64>::new());
        assert_eq!(h.deleted, caps, "the pin's two caps deleted");
        assert_eq!(h.clone(), h);
        let e = cut.edge_history(&[&block, &pin]).unwrap();
        assert_eq!((e.kept.len(), e.deleted.clone(), e.generated.len(), e.modified.clone()), (12, vec![(1, 1), (1, 2), (1, 3)], 3, vec![]));
        let plain = Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        assert_eq!(message(cut.history(&[&block, &plain])), "history: input 1 is not tracked");
        let one = message(cut.history(&[&block]));
        assert!(one.starts_with("history: face ") && one.contains(" names operand 1"), "{one}");
        assert_eq!(message(plain.edge_history(&[&block])), "edge_history: the result is not tracked");
    }

    #[test]
    fn identity_a_union_renumbers_the_second_operands_clashing_ids() {
        if !kernel_present() {
            return;
        }
        let a = Solid::cuboid(10.0, 10.0, 10.0).unwrap().tracked().unwrap();
        let b = Solid::cuboid(10.0, 10.0, 10.0).unwrap().translate(5.0, 5.0, 5.0).unwrap().tracked().unwrap();
        let joined = a.join(&b, DEFAULT_TOLERANCE).unwrap();
        assert_eq!(joined.faces().unwrap(), 12);
        let (mut firsts, mut seconds) = (std::collections::BTreeSet::new(), Vec::new());
        for f in 0..12 {
            let (k, id) = joined.face_origins(f).unwrap()[0];
            let own = joined.face_id(f).unwrap().unwrap();
            if k == 0 {
                assert_eq!(own, id);
                firsts.insert(id);
            } else {
                seconds.push((own, id));
            }
        }
        assert_eq!(firsts, (1..=6).collect());
        assert_eq!(seconds.iter().map(|s| s.0).collect::<Vec<_>>(), (7..=12).collect::<Vec<_>>(), "renumbered in face order");
        let named: std::collections::BTreeSet<u64> = seconds.iter().map(|s| s.1).collect();
        assert_eq!(named, (1..=6).collect(), "their origins name operand 1's own ids");
    }

    #[test]
    fn identity_a_split_halves_the_sides_and_its_bodies_keep_the_splits_origins() {
        if !kernel_present() {
            return;
        }
        let block = Solid::cuboid(2.0, 4.0, 6.0).unwrap().tracked().unwrap();
        let pieces = split_xy(&block);
        assert_eq!(pieces.len(), 2);
        let sides: Vec<u64> = (0..6).filter(|&f| nz(&block, f).abs() < 0.5).map(|f| block.face_id(f).unwrap().unwrap()).collect();
        assert_eq!(sides.len(), 4);
        let mut halves: BTreeMap<u64, Vec<u64>> = sides.iter().map(|&s| (s, Vec::new())).collect();
        let (mut cut_faces, mut caps) = (0, 0);
        for piece in &pieces {
            for f in 0..piece.faces().unwrap() {
                let (o, id) = (piece.face_origins(f).unwrap(), piece.face_id(f).unwrap().unwrap());
                if o.is_empty() {
                    assert!(id > 6, "a cut face is generated, with a fresh id");
                    cut_faces += 1;
                } else if sides.contains(&o[0].1) {
                    assert_eq!(o, vec![(0, o[0].1)]);
                    halves.get_mut(&o[0].1).unwrap().push(id);
                } else {
                    assert_eq!(o, vec![(0, id)], "a cap is kept");
                    caps += 1;
                }
            }
        }
        assert_eq!((cut_faces, caps), (2, 2));
        for (s, ids) in &halves {
            assert!(ids.len() == 2 && ids.iter().filter(|&&i| i == *s).count() == 1, "side {s} in two, one half keeping its id: {ids:?}");
        }
        for piece in &pieces {
            let h = piece.history(&[&block]).unwrap();
            assert_eq!((h.generated.len(), h.deleted.len()), (1, 1));
        }
    }

    #[test]
    fn identity_a_fillets_round_is_generated() {
        if !kernel_present() {
            return;
        }
        let block = Solid::cuboid(10.0, 10.0, 10.0).unwrap().tracked().unwrap();
        let rounded = block.fillet(&[0], 1.0, FILLET_TOLERANCE).unwrap();
        assert_eq!(rounded.faces().unwrap(), 7);
        let round = (0..7).find(|&f| rounded.face_kind(f).unwrap() != "plane").unwrap();
        assert_eq!(rounded.face_origins(round).unwrap(), vec![]);
        assert_eq!(rounded.face_id(round).unwrap(), Some(7));
        let h = rounded.history(&[&block]).unwrap();
        assert_eq!((h.generated.clone(), h.kept.len()), (vec![7], 6));
        assert_eq!(rounded.edge_with_id(1).unwrap(), None, "the rounded edge is gone");
    }

    #[test]
    fn identity_a_flush_join_merged_names_one_origin_per_input() {
        if !kernel_present() {
            return;
        }
        let a = Solid::cuboid(10.0, 10.0, 10.0).unwrap().tracked().unwrap();
        let b = Solid::cuboid(4.0, 10.0, 10.0).unwrap().translate(7.0, 0.0, 0.0).unwrap().tracked().unwrap();
        let joined = a.join(&b, DEFAULT_TOLERANCE).unwrap();
        let merged = joined.merge_flush().unwrap().origins_through(&joined).unwrap();
        assert_eq!(merged.faces().unwrap(), 6);
        let mut two = 0;
        for f in 0..6 {
            let o = merged.face_origins(f).unwrap();
            if merged.face_ref(f).unwrap()[4].abs() < 0.5 {
                assert_eq!(o.iter().map(|&(k, _)| k).collect::<Vec<_>>(), vec![0, 1], "face {f}: {o:?}");
                assert!(a.face_with_id(o[0].1).unwrap().is_some() && b.face_with_id(o[1].1).unwrap().is_some());
                two += 1;
            } else {
                assert_eq!(o.len(), 1, "face {f}: {o:?}");
            }
        }
        assert_eq!(two, 4);
        let h = merged.history(&[&a, &b]).unwrap();
        assert!(h.generated.is_empty() && h.deleted.len() == 2, "the two flush faces: {h:?}");
        assert_eq!(h.modified.iter().filter(|((k, _), outs)| *k == 1 && outs.len() == 1).count(), 4);
    }

    #[test]
    fn identity_the_same_chain_twice_numbers_the_same() {
        if !kernel_present() {
            return;
        }
        let run = || {
            let (block, pin) = block_and_pin();
            let cut = block.cut(&pin, DEFAULT_TOLERANCE).unwrap();
            let line = cut.edges().unwrap().into_iter().find(|e| e.is_line()).unwrap().index;
            let r = cut.fillet(&[line], 1.0, FILLET_TOLERANCE).unwrap();
            let faces: Vec<_> = (0..r.faces().unwrap()).map(|f| r.face_id(f).unwrap()).collect();
            let edges: Vec<_> = (0..r.edges().unwrap().len() as u32).map(|e| r.edge_id(e).unwrap()).collect();
            (faces, edges)
        };
        let first = run();
        assert!(first.0.iter().chain(&first.1).all(Option::is_some));
        assert_eq!(first, run());
    }

    #[test]
    fn identity_attributes_are_set_read_listed_and_refused() {
        if !kernel_present() {
            return;
        }
        let s = Solid::cuboid(1.0, 2.0, 3.0).unwrap().with_attribute("material", "steel").unwrap();
        assert!(s.is_tracked().unwrap(), "an attribute rides with the ids");
        assert_eq!(s.attribute("material").unwrap().as_deref(), Some("steel"));
        assert_eq!(s.attribute("absent").unwrap(), None);
        let pairs = |m: BTreeMap<String, String>| m.into_iter().collect::<Vec<_>>();
        let own = |k: &str, v: &str| (k.to_string(), v.to_string());
        assert_eq!(pairs(s.attributes().unwrap()), vec![own("material", "steel")]);
        let both = s.with_attributes([("zeta", "1"), ("alpha", "2")]).unwrap();
        assert_eq!(pairs(both.attributes().unwrap()), vec![own("alpha", "2"), own("material", "steel"), own("zeta", "1")]);
        let text = "acciaio inossidabile è ☃ \u{1f527}";
        assert_eq!(s.with_attribute("m", text).unwrap().attribute("m").unwrap().as_deref(), Some(text));
        assert_eq!(s.with_attribute("empty", "").unwrap().attribute("empty").unwrap().as_deref(), Some(""));
        assert_eq!(message(s.with_attribute("", "x")), "with_attribute: the key is empty");
        assert_eq!(pairs(s.without_attribute("absent").unwrap().attributes().unwrap()), vec![own("material", "steel")]);
        assert!(s.without_attribute("material").unwrap().attributes().unwrap().is_empty());
        assert!(Solid::cuboid(1.0, 1.0, 1.0).unwrap().attributes().unwrap().is_empty());
        let none: [(&str, &str); 0] = [];
        assert_eq!(pairs(s.with_attributes(none).unwrap().attributes().unwrap()), vec![own("material", "steel")]);
    }

    #[test]
    fn identity_face_attributes_survive_a_translate_and_a_split() {
        if !kernel_present() {
            return;
        }
        let block = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let side = (0..6).find(|&f| nz(&block, f).abs() < 0.5).unwrap();
        let s = block.with_face_attribute(side, "finish", "ground").unwrap();
        assert_eq!(s.face_attribute(side, "finish").unwrap().as_deref(), Some("ground"));
        let other = (side + 1) % 6;
        assert_eq!(s.face_attribute(other, "finish").unwrap(), None);
        assert!(s.face_attributes(other).unwrap().is_empty());
        let keys = |m: BTreeMap<String, String>| m.into_keys().collect::<Vec<_>>();
        assert_eq!(keys(s.face_attributes(side).unwrap()), vec!["finish"]);
        assert_eq!(s.face_attributes(side).unwrap()["finish"], "ground");
        let two = s.with_face_attributes(side, [("b", "1"), ("a", "2")]).unwrap();
        assert_eq!(keys(two.face_attributes(side).unwrap()), vec!["a", "b", "finish"]);
        assert_eq!(two.face_attribute(side, "a").unwrap().as_deref(), Some("2"));
        assert!(s.without_face_attribute(side, "finish").unwrap().face_attributes(side).unwrap().is_empty());
        assert_eq!(s.translate(5.0, 0.0, 0.0).unwrap().face_attribute(side, "finish").unwrap().as_deref(), Some("ground"));
        assert_eq!(message(s.face_attribute(6, "finish")), "face_attribute: face 6 is not one of the solid's 6");
        assert_eq!(message(s.with_face_attribute(side, "", "x")), "with_face_attribute: the key is empty");
        // A split face's pieces keep their parent's attributes.
        let side_id = s.face_id(side).unwrap().unwrap();
        let mut found = Vec::new();
        for p in split_xy(&s) {
            for f in 0..p.faces().unwrap() {
                if p.face_origins(f).unwrap().contains(&(0, side_id)) {
                    found.push(p.face_attribute(f, "finish").unwrap());
                }
            }
        }
        assert_eq!(found, vec![Some("ground".to_string()), Some("ground".to_string())]);
    }

    #[test]
    fn identity_a_solids_attributes_reach_step() {
        if !kernel_present() {
            return;
        }
        let text = Solid::cuboid(1.0, 2.0, 3.0).unwrap().with_attribute("material", "steel").unwrap().step_text(None, Unit::Millimetre).unwrap();
        assert_eq!(text.matches("PROPERTY_DEFINITION('material','user defined attribute',").count(), 1);
        assert!(text.contains("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')"));
        assert!(text.split("ENDSEC;").next().unwrap().contains("AP242"), "the header names the AP242 schema");
    }

    #[test]
    fn identity_edges_are_found_again_after_a_stretch_and_vertices_after_a_move() {
        if !kernel_present() {
            return;
        }
        let (cube, long) = (Solid::cuboid(10.0, 10.0, 10.0).unwrap(), Solid::cuboid(11.0, 10.0, 10.0).unwrap());
        let n = cube.edges().unwrap().len() as u32;
        let refs: Vec<[f64; 15]> = (0..n).map(|e| cube.edge_ref(e).unwrap()).collect();
        let found: Vec<u32> = refs.iter().map(|r| long.find_edge(r, 1e-3).unwrap().unwrap()).collect();
        let mut sorted = found.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..n).collect::<Vec<_>>(), "{found:?}");
        for (r, &g) in refs.iter().zip(&found) {
            let t = long.edge_ref(g).unwrap();
            let dot: f64 = (4..7).map(|i| r[i] * t[i]).sum();
            assert!(dot.abs() > 0.99, "edge {g}: tangents {:?} and {:?}", &r[4..7], &t[4..7]);
        }
        // A 14-number reference cannot be passed: the reference is a `[f64; 15]`.
        let mut bad = refs[0];
        bad[1] = f64::NAN;
        assert_eq!(message(cube.find_edge(&bad, 1e-3)), "find_edge: an edge reference is fifteen finite numbers");
        assert_eq!(message(cube.edge_ref(12)), "edge_ref: edge 12 of 12");
        assert_eq!(cube.vertex_count().unwrap(), 8);
        let moved = cube.translate(1e-4, 0.0, 0.0).unwrap();
        for v in 0..8 {
            let p = cube.vertex_ref(v).unwrap();
            assert_eq!(moved.find_vertex(&p, 1e-3).unwrap(), Some(v));
        }
        assert_eq!(cube.find_vertex(&[100.0, 0.0, 0.0], 1e-3).unwrap(), None);
        assert!(message(cube.find_vertex(&[0.0, 0.0, f64::NAN], 1e-3)).starts_with("find_vertex: "));
    }

    fn hits(pairs: &[(u32, f64)]) -> Vec<RTreeHit> {
        pairs.iter().map(|&(id, distance)| RTreeHit { id, distance }).collect()
    }

    #[test]
    fn rtree_a_ray_through_a_row() {
        if !kernel_present() {
            return;
        }
        let row: Vec<(u32, Aabb)> = (0..10).map(|i| (i, cell(i as f64, 0.0, 0.0, i as f64 + 1.0, 1.0, 1.0))).collect();
        let tree = RTree::from_boxes(&row).unwrap();
        let inf = f64::INFINITY;
        let all: Vec<(u32, f64)> = (0..10).map(|i| (i, i as f64 + 1.0)).collect();
        assert_eq!(tree.ray([-1.0, 0.5, 0.5], [1.0, 0.0, 0.0], inf).unwrap(), hits(&all));
        assert_eq!(tree.ray([-1.0, 0.5, 0.5], [2.0, 0.0, 0.0], 1.0).unwrap(), hits(&[(0, 0.5), (1, 1.0)]), "t in units of the direction");
        assert_eq!(tree.ray([-1.0, 0.5, 0.5], [1.0, 0.0, 0.0], 3.0).unwrap(), hits(&[(0, 1.0), (1, 2.0), (2, 3.0)]), "max_t cuts");
        assert_eq!(tree.ray([2.5, 0.5, 0.5], [1.0, 0.0, 0.0], 1.0).unwrap(), hits(&[(2, 0.0), (3, 0.5)]), "from inside: 0");
        assert_eq!(tree.ray([11.0, 0.5, 0.5], [-1.0, 0.0, 0.0], 2.0).unwrap(), hits(&[(9, 1.0), (8, 2.0)]));
        assert_eq!(tree.ray([-1.0, 1.0, 0.5], [1.0, 0.0, 0.0], inf).unwrap().len(), 10, "grazing the top face counts");
        assert!(tree.ray([-1.0, 1.0 + 1e-12, 0.5], [1.0, 0.0, 0.0], inf).unwrap().is_empty());
        assert_eq!(message(tree.ray([0.0; 3], [0.0; 3], inf)), "rtree_ray: direction (0, 0, 0) is not a direction");
        assert_eq!(message(tree.ray([0.0; 3], [1.0, 0.0, 0.0], -1.0)), "rtree_ray: max_t -1 is not a distance");
        assert_eq!(message(tree.ray([0.0; 3], [1.0, 0.0, 0.0], f64::NAN)), "rtree_ray: max_t NaN is not a distance");
        assert_eq!(message(tree.ray([f64::NAN, 0.0, 0.0], [1.0, 0.0, 0.0], inf)), "rtree_ray: origin (NaN, 0, 0) is not finite");
        assert_eq!(message(tree.ray([0.0; 3], [inf, 0.0, 0.0], inf)), "rtree_ray: direction (inf, 0, 0) is not finite");
    }

    #[test]
    fn rtree_from_triangles_boxes_each_triangle() {
        if !kernel_present() {
            return;
        }
        let positions = [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 3.0, 0.0], [f64::NAN, 0.0, 0.0], [5.0, 1.0, 4.0]];
        let tree = RTree::from_triangles(&positions, &[[0, 1, 2], [1, 4, 1]]).unwrap();
        assert_eq!(tree.len(), 2);
        assert_eq!(tree.bounds().unwrap(), Some(cell(0.0, 0.0, 0.0, 5.0, 3.0, 4.0)), "point 3 is used by no triangle");
        assert_eq!(tree.search(&cell(1.0, 1.0, 0.0, 1.0, 1.0, 0.0)).unwrap(), [0]);
        assert_eq!(tree.search(&cell(4.0, 0.5, 2.0, 4.0, 0.5, 2.0)).unwrap(), [1]);
        assert_eq!(tree.ray([-1.0, 0.5, 0.0], [1.0, 0.0, 0.0], f64::INFINITY).unwrap(), hits(&[(0, 1.0), (1, 3.0)]));
        assert!(RTree::from_triangles(&[], &[]).unwrap().is_empty());
        assert_eq!(
            message(RTree::from_triangles(&[[0.0; 3]; 4], &[[0, 1, 2], [0, 4, 1]])),
            "rtree_from_triangles: triangle 1 names point 4 of 4"
        );
        assert_eq!(
            message(RTree::from_triangles(&[[0.0; 3], [0.0, f64::INFINITY, 0.0]], &[[0, 1, 0]])),
            "rtree_from_triangles: triangle 0 point 1 is not finite"
        );
    }

    #[test]
    fn rtree_a_cuboids_face_tree() {
        if !kernel_present() {
            return;
        }
        let cuboid = Solid::cuboid(3.0, 4.0, 5.0).unwrap();
        let faces = cuboid.face_tree().unwrap();
        assert_eq!(faces.len(), 6);
        let grow = 5.0 * 1e-3;
        let b = faces.bounds().unwrap().unwrap();
        let near = |a: [f64; 3], w: [f64; 3]| a.iter().zip(w).all(|(x, y)| (x - y).abs() <= 1e-9);
        assert!(near(b.lo, [-1.5 - grow, -2.0 - grow, -2.5 - grow]) && near(b.hi, [1.5 + grow, 2.0 + grow, 2.5 + grow]), "{b:?}");
        assert_eq!(faces.search(&cell(1.4, 1.9, 2.4, 1.6, 2.1, 2.6)).unwrap().len(), 3, "three faces at a corner");
        let shot = faces.ray([10.0, 0.0, 0.0], [-1.0, 0.0, 0.0], f64::INFINITY).unwrap();
        assert_eq!(shot.len(), 2, "{shot:?}");
        assert!((shot[0].distance - (8.5 - grow)).abs() <= 1e-9 && (shot[1].distance - (11.5 - grow)).abs() <= 1e-9, "{shot:?}");
        // The +x face is the one the ray met first: a face call by that index agrees.
        assert!(near(cuboid.face_frame(shot[0].id).unwrap().z(), [1.0, 0.0, 0.0]));
        // The tree is its own: it outlives the solid.
        drop(cuboid);
        assert_eq!(faces.len(), 6);
    }

    #[test]
    fn containment_one_shot_and_classified() {
        if !kernel_present() {
            return;
        }
        let cuboid = Solid::cuboid(2.0, 3.0, 4.0).unwrap();
        assert_eq!(cuboid.contains([0.0, 0.0, 0.0], 0.05).unwrap(), "inside");
        assert_eq!(cuboid.contains([5.0, 0.0, 0.0], 0.05).unwrap(), "outside");
        assert_eq!(cuboid.contains([0.0, 0.0, 2.0], 0.05).unwrap(), "on");
        let classifier = cuboid.classifier(0.05).unwrap();
        for p in [[0.0, 0.0, 0.0], [0.99, 0.0, 0.0], [1.0, 0.0, 0.0], [1.2, 0.0, 0.0], [0.0, 1.6, 0.0], [0.0, 0.0, -2.0]] {
            assert_eq!(classifier.contains(p).unwrap(), cuboid.contains(p, 0.05).unwrap(), "{p:?}");
        }
        let sphere = Solid::sphere(1.5).unwrap();
        let c = sphere.classifier(1e-3).unwrap();
        let line: Vec<&str> = [-2.0, -1.4, -0.5, 0.0, 0.5, 1.4, 2.0].iter().map(|&x| c.contains([x, 0.0, 0.0]).unwrap()).collect();
        assert_eq!(line, ["outside", "inside", "inside", "inside", "inside", "inside", "outside"]);
        assert_eq!(c.contains([1.5, 0.0, 0.0]).unwrap(), "on");
        assert_eq!(c.contains([0.0, 0.0, -1.5]).unwrap(), "on");
    }

    #[test]
    fn a_classifier_outlives_its_solid() {
        if !kernel_present() {
            return;
        }
        let sphere = Solid::sphere(1.0).unwrap();
        let c = sphere.classifier(1e-3).unwrap();
        drop(sphere);
        assert_eq!(c.contains([0.0, 0.0, 0.0]).unwrap(), "inside");
        assert_eq!(c.contains([2.0, 0.0, 0.0]).unwrap(), "outside");
        assert_eq!(c.contains([1.0, 0.0, 0.0]).unwrap(), "on");
    }

    #[test]
    fn containment_refusals() {
        if !kernel_present() {
            return;
        }
        let cuboid = Solid::cuboid(2.0, 3.0, 4.0).unwrap();
        let nan = [f64::NAN, 0.0, 0.0];
        let m = message(cuboid.contains(nan, 0.05));
        assert!(m.starts_with("contains: ") && m.contains("not finite"), "{m}");
        let c = cuboid.classifier(0.05).unwrap();
        let m = message(c.contains(nan));
        assert!(m.starts_with("classifier_contains: ") && m.contains("not finite"), "{m}");
        let m = message(cuboid.contains([0.0; 3], -1.0));
        assert!(m.starts_with("contains: ") && m.contains("positive and finite"), "{m}");
        let m = message(cuboid.classifier(-1.0));
        assert!(m.starts_with("classifier_new: ") && m.contains("positive and finite"), "{m}");
    }

    #[test]
    fn the_closest_points_of_two_spheres() {
        if !kernel_present() {
            return;
        }
        let a = Solid::sphere(1.0).unwrap();
        let b = Solid::sphere(1.0).unwrap().translate(5.0, 0.0, 0.0).unwrap();
        let ab = a.closest(&b, 1e-3).unwrap();
        near(ab.distance, 3.0, 6e-9, "distance");
        assert!(ab.refined);
        assert_eq!((ab.kind_a.as_str(), ab.kind_b.as_str()), ("face", "face"));
        assert_eq!((ab.edge_a, ab.edge_b), (None, None));
        near3(ab.on_a, [1.0, 0.0, 0.0], 1e-6, "on_a");
        near3(ab.on_b, [4.0, 0.0, 0.0], 1e-6, "on_b");
        let ba = b.closest(&a, 1e-3).unwrap();
        near3(ba.on_a, ab.on_b, 1e-9, "swapped on_a");
        near3(ba.on_b, ab.on_a, 1e-9, "swapped on_b");
        near(ba.distance, ab.distance, 1e-12, "swapped distance");
    }

    #[test]
    fn the_closest_point_can_name_a_filletable_edge() {
        if !kernel_present() {
            return;
        }
        let cuboid = Solid::cuboid(2.0, 3.0, 4.0).unwrap();
        let ball = Solid::sphere(1.0).unwrap().translate(3.0, 0.0, 4.0).unwrap();
        let c = cuboid.closest(&ball, 1e-3).unwrap();
        near(c.distance, 2.0 * 2f64.sqrt() - 1.0, 2e-3, "distance");
        assert_eq!(c.kind_a, "edge");
        let edge = c.edge_a.expect("the edge is in the fillet table");
        assert_eq!(c.kind_b, "face");
        assert_eq!(c.edge_b, None);
        let rounded = cuboid.fillet(&[edge], 0.2, 1e-3).unwrap();
        assert_eq!(rounded.faces().unwrap(), cuboid.faces().unwrap() + 1);
    }

    #[test]
    fn closest_refuses_a_zero_tolerance() {
        if !kernel_present() {
            return;
        }
        let a = Solid::sphere(1.0).unwrap();
        let b = Solid::sphere(1.0).unwrap().translate(5.0, 0.0, 0.0).unwrap();
        assert!(message(a.closest(&b, -1.0)).starts_with("closest: "));
    }

    // ---- clash (clash plan 3) ----------------------------------------------------------

    /// The frame at `(x, y, z)` with the world's axes.
    fn at(x: f64, y: f64, z: f64) -> Frame {
        Frame::new([x, y, z], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]).unwrap()
    }

    fn pairs(rows: &[Clash]) -> Vec<(u32, u32, &str)> {
        rows.iter().map(|r| (r.a, r.b, r.kind.as_str())).collect()
    }

    #[test]
    fn clash_struct_has_the_headers_layout() {
        use std::mem::{offset_of, size_of};
        type C = sys::CadaclysmBlacksmithClash;
        let offsets = [
            offset_of!(C, a),
            offset_of!(C, b),
            offset_of!(C, kind),
            offset_of!(C, distance),
            offset_of!(C, on_a),
            offset_of!(C, on_b),
            offset_of!(C, kind_a),
            offset_of!(C, index_a),
            offset_of!(C, edge_a),
            offset_of!(C, kind_b),
            offset_of!(C, index_b),
            offset_of!(C, edge_b),
            offset_of!(C, refined),
            offset_of!(C, depth),
            offset_of!(C, text),
        ];
        assert_eq!(offsets, [0, 4, 8, 16, 24, 48, 72, 80, 84, 88, 96, 100, 104, 112, 120]);
        assert_eq!(size_of::<C>(), 128);
    }

    #[test]
    fn clash_balls_within_the_clearance_are_too_close() {
        if !kernel_present() {
            return;
        }
        let (a, b) = (Solid::sphere(1.0).unwrap(), Solid::sphere(1.0).unwrap());
        let collider = Collider::new(&[&a, &b], 1e-3, None, &[]).unwrap();
        let rows = collider.clash(&[at(0.0, 0.0, 0.0), at(2.5, 0.0, 0.0)], 1.0, None).unwrap();
        assert_eq!(pairs(&rows), [(0, 1, "too_close")]);
        let r = &rows[0];
        near(r.distance, 0.5, 1e-3, "distance");
        assert_eq!((r.kind_a.as_str(), r.kind_b.as_str()), ("face", "face"));
        assert!(r.index_a.is_some() && r.index_b.is_some(), "{r:?}");
        assert_eq!((r.edge_a, r.edge_b), (None, None));
        near(r.on_a[0], 1.0, 2e-3, "on_a.x");
        near(r.on_b[0], 1.5, 2e-3, "on_b.x");
        assert_eq!(r.text, "");
        assert_eq!(r.depth, 0.0);
        let _: bool = r.refined;
        assert!(collider.clash(&[at(0.0, 0.0, 0.0), at(2.5, 0.0, 0.0)], 0.25, None).unwrap().is_empty());
    }

    #[test]
    fn clash_boxes_face_to_face_touch_and_intersect_on_the_shared_face() {
        if !kernel_present() {
            return;
        }
        let (a, b) = (Solid::cuboid(2.0, 2.0, 2.0).unwrap(), Solid::cuboid(2.0, 2.0, 2.0).unwrap());
        let collider = Collider::new(&[&a, &b], 1e-3, None, &[]).unwrap();
        let rows = collider.clash(&[at(0.0, 0.0, 0.0), at(2.0, 0.0, 0.0)], 0.0, None).unwrap();
        drop(collider);
        assert_eq!(pairs(&rows), [(0, 1, "touching")]);
        let r = &rows[0];
        assert!(r.distance <= 1e-3, "{r:?}");
        assert!(message(r.solid()).starts_with("clashes_solid: pair (0, 1) is not penetrating"));
        let x = r.intersect().unwrap();
        assert_eq!(x.overlaps.len(), 1, "{x:?}");
        let ring = &x.overlaps[0].loops[0];
        assert!(ring.iter().all(|p| (p[0] - 1.0).abs() <= 1e-3), "{ring:?}");
        let n = ring.len();
        let area = (0..n).map(|i| ring[i][1] * ring[(i + 1) % n][2] - ring[(i + 1) % n][1] * ring[i][2]).sum::<f64>().abs() / 2.0;
        near(area, 4.0, 1e-6, "shared face area");
    }

    #[test]
    fn clash_boxes_interpenetrating_report_depth_and_rebuild_the_overlap() {
        if !kernel_present() {
            return;
        }
        let (a, b) = (Solid::cuboid(2.0, 2.0, 2.0).unwrap(), Solid::cuboid(2.0, 2.0, 2.0).unwrap());
        let collider = Collider::new(&[&a, &b], 1e-3, None, &[]).unwrap();
        let rows = collider.clash(&[at(0.0, 0.0, 0.0), at(1.75, 0.0, 0.0)], 0.0, None).unwrap();
        drop(collider);
        assert_eq!(pairs(&rows), [(0, 1, "penetrating")]);
        // One row kept, the list (and the collider) gone: the row keeps the handle alive.
        let r = rows.into_iter().next().unwrap();
        assert_eq!(Rc::strong_count(&r.keeper), 1, "the row is the handle's last owner");
        assert!((r.depth - 0.25).abs() < 1e-9, "{r:?}");
        assert_eq!(r.distance, 0.0);
        assert_eq!((r.kind_a.as_str(), r.index_a, r.edge_a), ("none", None, None));
        assert_eq!((r.kind_b.as_str(), r.index_b, r.edge_b), ("none", None, None));
        near(r.solid().unwrap().mass(1e-6).unwrap().volume, 1.0, 1e-6, "shared volume");
        r.intersect().unwrap();
    }

    #[test]
    fn clash_rows_of_one_call_share_one_handle() {
        if !kernel_present() {
            return;
        }
        let parts: Vec<Solid> = (0..3).map(|_| Solid::cuboid(2.0, 2.0, 2.0).unwrap()).collect();
        let refs: Vec<&Solid> = parts.iter().collect();
        let rows = clash(&refs, None, 0.0, 1e-3, &[]).unwrap();
        assert_eq!(pairs(&rows), [(0, 1, "penetrating"), (0, 2, "penetrating"), (1, 2, "penetrating")]);
        assert!(rows.iter().all(|r| Rc::ptr_eq(&r.keeper, &rows[0].keeper)));
        assert_eq!(Rc::strong_count(&rows[0].keeper), 3, "every row, and nothing else, owns the handle");
        let last = rows.into_iter().nth(2).unwrap();
        assert_eq!(Rc::strong_count(&last.keeper), 1);
        near(last.solid().unwrap().mass(1e-6).unwrap().volume, 8.0, 1e-6, "coincident cubes share all of it");
    }

    #[test]
    fn clash_one_shot_indexes_the_second_set_and_agrees_with_the_collider() {
        if !kernel_present() {
            return;
        }
        let a0 = Solid::sphere(1.0).unwrap();
        let a1 = Solid::sphere(1.0).unwrap().translate(2.05, 0.0, 0.0).unwrap();
        let b0 = Solid::sphere(1.0).unwrap().translate(0.0, 2.5, 0.0).unwrap();
        let b1 = Solid::sphere(1.0).unwrap().translate(10.0, 0.0, 0.0).unwrap();
        let two = clash(&[&a0, &a1], Some(&[&b0, &b1]), 1.0, 1e-3, &[]).unwrap();
        assert_eq!(pairs(&two), [(0, 0, "too_close")]);
        near(two[0].distance, 0.5, 1e-3, "distance");
        let collider = Collider::new(&[&a0, &a1, &b0, &b1], 1e-3, None, &[]).unwrap();
        let o = at(0.0, 0.0, 0.0);
        let via = collider.clash(&[o, o, o, o], 1.0, None).unwrap();
        let same = via.iter().find(|r| (r.a, r.b) == (0, 2)).unwrap();
        assert_eq!(same.kind, two[0].kind);
        near(same.distance, two[0].distance, 1e-3, "collider distance");
        let one = clash(&[&a0, &a1], None, 1.0, 1e-3, &[]).unwrap();
        assert_eq!(one.iter().map(|r| (r.a, r.b)).collect::<Vec<_>>(), [(0, 1)]);
        assert!(clash(&[&a0, &a1], None, 1.0, 1e-3, &[(0, 1)]).unwrap().is_empty());
    }

    #[test]
    fn clash_refusals_carry_the_calls_prefix() {
        if !kernel_present() {
            return;
        }
        let (a, b) = (Solid::cuboid(2.0, 2.0, 2.0).unwrap(), Solid::cuboid(2.0, 2.0, 2.0).unwrap());
        let collider = Collider::new(&[&a, &b], DEFAULT_TOLERANCE, None, &[]).unwrap();
        let pose = [at(0.0, 0.0, 0.0), at(1.75, 0.0, 0.0)];
        let m = message(collider.clash(&pose, -1.0, None));
        assert!(m.starts_with("collider_clash: clearance -1"), "{m}");
        let m = message(collider.clash(&pose[..1], 0.0, None));
        assert!(m.starts_with("collider_clash: 1 frames for 2 groups"), "{m}");
        let m = message(collider.clash(&pose, 0.0, Some((2, 2))));
        assert!(m.starts_with("collider_clash: share (2, 2)"), "{m}");
        assert_eq!(pairs(&collider.clash(&pose, 0.0, None).unwrap()), [(0, 1, "penetrating")]);
        let m = message(clash(&[&a, &b], None, -1.0, DEFAULT_TOLERANCE, &[]));
        assert!(m.starts_with("clash: clearance -1"), "{m}");
        let m = message(clash(&[&a, &b], None, 0.0, DEFAULT_TOLERANCE, &[(5, 0)]));
        assert!(m.starts_with("clash: allowed pair (5, 0) names a part out of range"), "{m}");
        let m = message(clash(&[&a, &b], Some(&[]), 0.0, DEFAULT_TOLERANCE, &[]));
        assert!(m.starts_with("clash: an empty set"), "{m}");
    }

    #[test]
    fn clash_names_the_edges_of_two_boxes_edge_to_edge() {
        if !kernel_present() {
            return;
        }
        let (a, b) = (Solid::cuboid(2.0, 2.0, 2.0).unwrap(), Solid::cuboid(2.0, 2.0, 2.0).unwrap());
        let collider = Collider::new(&[&a, &b], 1e-3, None, &[]).unwrap();
        let c = 0.5f64.sqrt();
        let s = 0.1 * c;
        let turned = Frame::new([2.0 + s, 2.0 + s, 0.0], [c, -c, 0.0], [0.5, 0.5, c], [-0.5, -0.5, c]).unwrap();
        let rows = collider.clash(&[at(0.0, 0.0, 0.0), turned], 0.5, None).unwrap();
        assert_eq!(pairs(&rows), [(0, 1, "too_close")]);
        let r = &rows[0];
        near(r.distance, 0.1, 1e-3, "distance");
        near3(r.on_a, [1.0, 1.0, 0.0], 2e-3, "on_a");
        assert_eq!((r.kind_a.as_str(), r.kind_b.as_str()), ("edge", "edge"));
        let edges_a = a.edges().unwrap();
        let edge_a = &edges_a[r.edge_a.expect("a's edge is in the table") as usize];
        for p in edge_a.segments.iter().flatten() {
            near(p[0], 1.0, 2e-3, "a's edge x");
            near(p[1], 1.0, 2e-3, "a's edge y");
        }
        let edge_b = r.edge_b.expect("b's edge is in the table");
        assert!((edge_b as usize) < b.edges().unwrap().len());
    }

    #[test]
    fn clash_keeps_each_sides_feature_apart() {
        if !kernel_present() {
            return;
        }
        // `Solid::closest`'s pose: the cuboid's edge against the ball's face, the sides told apart.
        let cuboid = Solid::cuboid(2.0, 3.0, 4.0).unwrap();
        let ball = Solid::sphere(1.0).unwrap().translate(3.0, 0.0, 4.0).unwrap();
        let rows = clash(&[&cuboid], Some(&[&ball]), 2.0, 1e-3, &[]).unwrap();
        assert_eq!(pairs(&rows), [(0, 0, "too_close")]);
        let r = &rows[0];
        near(r.distance, 2.0 * 2f64.sqrt() - 1.0, 2e-3, "distance");
        assert_eq!((r.kind_a.as_str(), r.kind_b.as_str()), ("edge", "face"));
        assert!(r.edge_a.is_some() && r.edge_b.is_none(), "{r:?}");
        let closest = cuboid.closest(&ball, 1e-3).unwrap();
        assert_eq!((r.index_a, r.edge_a, r.index_b), (Some(closest.index_a), closest.edge_a, Some(closest.index_b)));
    }

    // ---- swept clash (swept clash plan 2b) ---------------------------------------------
    // The closed forms of crates/cadaclysm-blacksmith-capi/tests/swept_abi.rs: a 2-cube moving
    // along x from -5 to 5 through a 2-cube at the origin meets it at t = 0.3 and leaves at
    // 0.7, at a relative speed of 10 a segment.

    const SWEPT_TOL: f64 = 1e-3;
    const SWEPT_RES: f64 = 1e-3;

    fn at_x(x: f64) -> Frame {
        at(x, 0.0, 0.0)
    }

    fn swept_cubes() -> (Solid, Solid) {
        (Solid::cuboid(2.0, 2.0, 2.0).unwrap(), Solid::cuboid(2.0, 2.0, 2.0).unwrap())
    }

    fn swept_near(got: f64, want: f64, slack: f64, what: &str, rows: &[SweptClash]) {
        assert!((got - want).abs() <= slack, "{what}: {got} against {want} (slack {slack}): {rows:?}");
    }

    #[test]
    fn swept_clash_struct_has_the_headers_layout() {
        use std::mem::{offset_of, size_of};
        type S = sys::CadaclysmBlacksmithSweptClash;
        let offsets = [offset_of!(S, a), offset_of!(S, b), offset_of!(S, first_time), offset_of!(S, interval_count)];
        assert_eq!(offsets, [0, 4, 8, 16]);
        assert_eq!(size_of::<S>(), 24);
    }

    #[test]
    fn swept_clash_a_cube_through_a_cube() {
        if !kernel_present() {
            return;
        }
        let (a, b) = swept_cubes();
        let collider = Collider::new(&[&a, &b], SWEPT_TOL, None, &[]).unwrap();
        let rows = collider.swept_clash(&[&[at_x(-5.0), at_x(0.0)], &[at_x(5.0), at_x(0.0)]], 0.0, SWEPT_RES, 100_000, None).unwrap();
        drop(collider);
        drop((a, b));
        assert_eq!(rows.len(), 1, "{rows:?}");
        let r = &rows[0];
        assert_eq!((r.a, r.b), (0, 1));
        swept_near(r.first_time, 0.3, SWEPT_TOL / 10.0 + 1e-9, "first_time", &rows);
        assert_eq!(r.intervals.len(), 1, "{rows:?}");
        let (start, end) = r.intervals[0];
        assert_eq!(start, r.first_time);
        swept_near(end, 0.7, SWEPT_RES + SWEPT_TOL / 10.0, "end", &rows);
        assert_eq!((r.first.a, r.first.b, r.first.kind.as_str()), (0, 1, "touching"));
        // The first row keeps its own clashes handle: the collider and the solids are gone, the
        // contact still rebuilds.
        assert!(message(r.first.solid()).starts_with("clashes_solid: pair (0, 1) is not penetrating"));
        let found = r.first.intersect().unwrap();
        assert_eq!(found.overlaps.len(), 1, "{found:?}");
        let points: Vec<&[f64; 3]> = found.overlaps[0].loops.iter().flatten().collect();
        assert!(!points.is_empty());
        assert!(points.iter().all(|p| (p[0] + 1.0).abs() <= 2.0 * SWEPT_TOL), "{points:?}");
    }

    #[test]
    fn swept_clash_there_and_back_is_two_intervals() {
        if !kernel_present() {
            return;
        }
        let (a, b) = swept_cubes();
        let collider = Collider::new(&[&a, &b], SWEPT_TOL, None, &[]).unwrap();
        let poses: [&[Frame]; 3] = [&[at_x(-5.0), at_x(0.0)], &[at_x(5.0), at_x(0.0)], &[at_x(-5.0), at_x(0.0)]];
        let rows = collider.swept_clash(&poses, 0.0, SWEPT_RES, 100_000, None).unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].intervals.len(), 2, "{rows:?}");
        for (&(start, end), (want_start, want_end)) in rows[0].intervals.iter().zip([(0.3, 0.7), (1.3, 1.7)]) {
            swept_near(start, want_start, SWEPT_TOL / 10.0 + 1e-9, "start", &rows);
            swept_near(end, want_end, SWEPT_RES + SWEPT_TOL / 10.0, "end", &rows);
        }
    }

    #[test]
    fn swept_clash_a_miss_is_seen_only_within_the_clearance() {
        if !kernel_present() {
            return;
        }
        let (a, b) = swept_cubes();
        let collider = Collider::new(&[&a, &b], SWEPT_TOL, None, &[]).unwrap();
        let passing: [&[Frame]; 2] = [&[at(-5.0, 2.5, 0.0), at_x(0.0)], &[at(5.0, 2.5, 0.0), at_x(0.0)]];
        assert!(collider.swept_clash(&passing, 0.4, SWEPT_RES, 100_000, None).unwrap().is_empty());
        let rows = collider.swept_clash(&passing, 0.6, SWEPT_RES, 100_000, None).unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        let r = &rows[0];
        assert_eq!(r.first.kind, "too_close");
        assert!(0.5 - SWEPT_TOL <= r.first.distance && r.first.distance <= 0.6, "{rows:?}");
        assert_eq!(r.intervals.len(), 1, "{rows:?}");
    }

    #[test]
    fn swept_clash_a_pair_starting_inside_rebuilds_the_overlap_at_its_first_time() {
        if !kernel_present() {
            return;
        }
        // The cubes share a 0.25 slab at t = 0, then a moves clear.
        let (a, b) = swept_cubes();
        let collider = Collider::new(&[&a, &b], SWEPT_TOL, None, &[]).unwrap();
        let rows = collider.swept_clash(&[&[at_x(1.75), at_x(0.0)], &[at_x(5.0), at_x(0.0)]], 0.0, SWEPT_RES, 100_000, None).unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        let r = &rows[0];
        assert_eq!(r.first_time, 0.0);
        assert_eq!(r.first.kind, "penetrating");
        near(r.first.solid().unwrap().mass(1e-6).unwrap().volume, 1.0, 1e-6, "shared volume");
    }

    #[test]
    fn swept_clash_one_shot_indexes_the_second_set_and_agrees_with_the_collider() {
        if !kernel_present() {
            return;
        }
        // Set a still at the origin and at y = 20; set b carried along x through them.
        let a0 = Solid::cuboid(2.0, 2.0, 2.0).unwrap();
        let a1 = Solid::cuboid(2.0, 2.0, 2.0).unwrap().translate(0.0, 20.0, 0.0).unwrap();
        let (b0, b1) = swept_cubes();
        let still: [&[Frame]; 2] = [&[at_x(0.0), at_x(0.0)], &[at_x(0.0), at_x(0.0)]];
        let moving: [&[Frame]; 2] = [&[at_x(-5.0), at(-5.0, 20.0, 0.0)], &[at_x(5.0), at(5.0, 20.0, 0.0)]];
        let two = swept_clash(&[&a0, &a1], &still, Some((&[&b0, &b1], &moving)), 0.0, SWEPT_TOL, SWEPT_RES, 100_000, &[]).unwrap();
        assert_eq!(two.iter().map(|r| (r.a, r.b)).collect::<Vec<_>>(), [(0, 0), (1, 1)], "{two:?}");
        assert_eq!(two.iter().map(|r| (r.first.a, r.first.b)).collect::<Vec<_>>(), [(0, 0), (1, 1)], "{two:?}");
        let collider = Collider::new(&[&a0, &a1, &b0, &b1], SWEPT_TOL, None, &[]).unwrap();
        let joined: Vec<Vec<Frame>> = still.iter().zip(&moving).map(|(sa, sb)| [*sa, *sb].concat()).collect();
        let joined: Vec<&[Frame]> = joined.iter().map(Vec::as_slice).collect();
        let via = collider.swept_clash(&joined, 0.0, SWEPT_RES, 100_000, None).unwrap();
        let shifted: Vec<_> = via.iter().map(|r| (r.a, r.b - 2, r.first_time, r.intervals.clone())).collect();
        let direct: Vec<_> = two.iter().map(|r| (r.a, r.b, r.first_time, r.intervals.clone())).collect();
        assert_eq!(shifted, direct);
        let crossing: [&[Frame]; 2] = [&[at_x(0.0), at_x(-5.0)], &[at_x(0.0), at_x(5.0)]];
        let one = swept_clash(&[&a0, &b0], &crossing, None, 0.0, SWEPT_TOL, SWEPT_RES, 100_000, &[]).unwrap();
        assert_eq!(one.iter().map(|r| (r.a, r.b)).collect::<Vec<_>>(), [(0, 1)]);
        assert!(swept_clash(&[&a0, &b0], &crossing, None, 0.0, SWEPT_TOL, SWEPT_RES, 100_000, &[(0, 1)]).unwrap().is_empty());
    }

    #[test]
    fn swept_clash_refusals_carry_the_calls_prefix() {
        if !kernel_present() {
            return;
        }
        let (a, b) = swept_cubes();
        let through: [&[Frame]; 2] = [&[at_x(-5.0), at_x(0.0)], &[at_x(5.0), at_x(0.0)]];
        let collider = Collider::new(&[&a, &b], SWEPT_TOL, None, &[]).unwrap();
        let refused = |poses: &[&[Frame]], clearance: f64, resolution: f64, max_steps: u32, share: Option<(u32, u32)>, want: &str| {
            let m = message(collider.swept_clash(poses, clearance, resolution, max_steps, share));
            assert!(m.starts_with(want), "{m:?} does not start {want:?}");
        };
        refused(&through[..1], 0.0, SWEPT_RES, 100_000, None, "collider_swept_clash: 1 poses, at least 2 are needed");
        refused(&[&[at_x(0.0)], &[at_x(0.0)]], 0.0, SWEPT_RES, 100_000, None, "collider_swept_clash: 1 frames for 2 groups");
        // Ragged: C reads every pose at one frame count, so this one is the wrapper's own.
        refused(&[&[at_x(0.0), at_x(0.0)], &[at_x(0.0)]], 0.0, SWEPT_RES, 100_000, None, "collider_swept_clash: 1 frames for 2 groups");
        refused(&through, 0.0, 0.0, 100_000, None, "collider_swept_clash: resolution 0");
        refused(&through, 0.0, SWEPT_RES, 0, None, "collider_swept_clash: max_steps must be at least 1");
        refused(&through, -1.0, SWEPT_RES, 100_000, None, "collider_swept_clash: clearance -1");
        refused(&through, 0.0, SWEPT_RES, 100_000, Some((2, 2)), "collider_swept_clash: share (2, 2)");

        // The one-shot. `others` and its poses are one `Option`, so "others and other_poses go
        // together" cannot be asked here.
        let still: [&[Frame]; 2] = [&[at_x(0.0)], &[at_x(0.0)]];
        let one_shot = |parts: &[&Solid], poses: &[&[Frame]], others: Option<(&[&Solid], &[&[Frame]])>, max_steps: u32, allowed: &[(u32, u32)], want: &str| {
            let m = message(swept_clash(parts, poses, others, 0.0, SWEPT_TOL, SWEPT_RES, max_steps, allowed));
            assert!(m.starts_with(want), "{m:?} does not start {want:?}");
        };
        one_shot(&[&a], &still, Some((&[&b], &still[..1])), 100_000, &[], "swept_clash: 2 poses for set a, 1 for set b");
        one_shot(&[&a], &still, Some((&[&b], &[&[at_x(0.0)], &[at_x(0.0), at_x(0.0)]])), 100_000, &[], "swept_clash: pose 1 of set b has 2 frames for 1 parts");
        one_shot(&[&a], &[&[at_x(0.0), at_x(0.0)], &[at_x(0.0)]], None, 100_000, &[], "swept_clash: pose 0 of set a has 2 frames for 1 parts");
        one_shot(&[&a], &still, Some((&[], &[&[], &[]])), 100_000, &[], "swept_clash: an empty set");
        one_shot(&[&a, &b], &through, None, 100_000, &[(5, 0)], "swept_clash: allowed pair (5, 0) names a part out of range");
        one_shot(&[&a, &b], &through, None, 0, &[], "swept_clash: max_steps must be at least 1");
        one_shot(&[&a, &b], &through[..1], None, 100_000, &[], "swept_clash: 1 poses, at least 2 are needed");
    }

    // ---- Sketch: the 2D constraint sketcher -----------------------------------------

    fn sk_rect() -> (Sketch, [u32; 4], [u32; 4]) {
        let s = Sketch::new().unwrap();
        let (corners, sides) = s.add_rect([0.0, 0.0], [40.0, 30.0]).unwrap();
        (s, corners, sides)
    }

    fn sk_sorted(ids: &[u32]) -> Vec<u32> {
        let mut out = ids.to_vec();
        out.sort_unstable();
        out
    }

    fn sk_refusal<T: fmt::Debug>(result: Result<T>) -> Error {
        result.expect_err("the sketch should have refused this")
    }

    #[test]
    fn a_sketch_is_send_and_an_error_carries_no_ids_unless_a_sketch_gave_them() {
        fn send<T: Send>() {}
        send::<Sketch>();
        assert!(Error::new("plain").ids().is_empty());
        assert_eq!(Error::new("plain").with_ids(vec![3, 1]).ids(), [3, 1]);
    }

    #[test]
    fn a_count_the_library_sends_as_a_double_is_converted_exactly() {
        assert_eq!(sketch_whole(0.0, "x").unwrap(), 0);
        assert_eq!(sketch_whole(7.0, "x").unwrap(), 7);
        assert_eq!(sketch_whole(f64::from(i32::MAX), "x").unwrap(), i32::MAX as u32);
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, 0.5, f64::from(i32::MAX) + 1.0, u32::MAX as f64] {
            let reason = sketch_whole(bad, "sketch_diagnose").unwrap_err();
            assert!(
                reason.message().starts_with("sketch_diagnose: the library answered "),
                "{bad} was converted or refused in other words: {reason}"
            );
        }
    }

    #[test]
    fn a_sketch_dimensions_a_plate_and_extrudes_it() {
        if !kernel_present() {
            return;
        }
        let (s, corners, sides) = sk_rect();
        s.fix(corners[0]).unwrap();
        let width = s.length(sides[0], 60.0, true).unwrap();
        s.length(sides[1], 30.0, true).unwrap();
        let hole = s.add_circle(s.add_point(30.0, 15.0).unwrap(), 5.0).unwrap();
        s.radius_of(hole, 5.0, true).unwrap();
        let report = s.solve().unwrap();
        assert!(report.converged() && report.status == "converged" && report.ids.is_empty(), "{report:?}");
        let p = s.point(corners[1]).unwrap();
        assert!((p[0] - 60.0).abs() <= 1e-9 && p[1].abs() <= 1e-9, "corner 1 is at {p:?}");
        assert_eq!(s.constraint_kind(width).unwrap(), "length");
        assert_eq!(s.constraint_value(width).unwrap(), Some(60.0));
        let dof = s.diagnose().unwrap();
        assert_eq!((dof.free, dof.state), (2, "under"), "{dof:?}");
        assert!(!dof.parts.is_empty() && dof.parts.iter().all(|p| p.free <= p.params), "{dof:?}");
        let profiles = s.profiles(1e-9).unwrap();
        assert_eq!(profiles.len(), 1);
        let body = Solid::extrude(&profiles[0], &Frame::xy([0.0; 3]), 10.0).unwrap();
        assert!(body.mass(0.0).unwrap().volume > 0.0);
    }

    #[test]
    fn a_sketch_refuses_a_conflict_and_the_refusal_carries_the_ids() {
        if !kernel_present() {
            return;
        }
        let (s, corners, sides) = sk_rect();
        s.fix(corners[0]).unwrap();
        s.length(sides[0], 40.0, true).unwrap();
        s.length(sides[1], 30.0, true).unwrap();
        let conflict = sk_refusal(s.distance(corners[0], corners[2], 10.0, true));
        assert!(conflict.message().starts_with("sketch_constrain: over-constrained"), "{conflict}");
        assert_eq!(conflict.ids(), [0, 1, 5, 6]);
        assert_eq!(s.constraints().unwrap().len(), 7, "the refused constraint was kept");
        let in_use = sk_refusal(s.remove_entity(corners[0]));
        assert!(in_use.message().starts_with("sketch_remove_entity: point"), "{in_use}");
        assert_eq!(sk_sorted(in_use.ids()), sk_sorted(&[sides[0], sides[3]]));
        let unknown = sk_refusal(s.kind(9999));
        assert!(unknown.message().contains("sketch_kind"), "{unknown}");
        assert!(unknown.ids().is_empty(), "kind(9999) carries the ids {:?}", unknown.ids());
    }

    #[test]
    fn a_sketch_drag_moves_the_point_it_holds() {
        if !kernel_present() {
            return;
        }
        let (s, corners, _) = sk_rect();
        let report = s.drag(&[(corners[0], [5.0, 5.0])]).unwrap();
        assert!(report.converged() && report.ids.is_empty(), "{report:?}");
        let p = s.point(corners[0]).unwrap();
        assert!((p[0] - 5.0).abs() <= 1e-9 && (p[1] - 5.0).abs() <= 1e-9, "{p:?}");
        assert!((s.point(corners[1]).unwrap()[1] - 5.0).abs() <= 1e-9, "the side does not stay level");
    }

    #[test]
    fn a_sketch_reference_follows_its_source() {
        if !kernel_present() {
            return;
        }
        let (plate, corners, sides) = sk_rect();
        let boss = Sketch::new().unwrap();
        plate.fix(corners[0]).unwrap();
        let width = plate.length(sides[0], 40.0, true).unwrap();
        plate.length(sides[1], 30.0, true).unwrap();
        let edge = boss.reference(&plate, sides[1]).unwrap();
        assert!(boss.is_reference(edge) && boss.is_construction(edge));
        let o = boss.add_point(130.0, 15.0).unwrap();
        let hole = boss.add_circle(o, 12.0).unwrap();
        boss.radius_of(hole, 12.0, true).unwrap();
        boss.point_line_distance(o, edge, 100.0, true, "auto").unwrap();
        assert!((boss.point(o).unwrap()[0] - 140.0).abs() <= 1e-9);
        assert_eq!(boss.profiles(1e-9).unwrap().len(), 1);
        assert!(plate.set_value(width, 60.0).unwrap().converged());
        let report = boss.update_reference(edge, &plate).unwrap();
        assert!(report.converged() && report.ids.is_empty(), "{report:?}");
        assert!((boss.point(o).unwrap()[0] - 160.0).abs() <= 1e-9);
        let not_a_reference = sk_refusal(boss.update_reference(o, &plate));
        assert!(not_a_reference.message().starts_with("sketch_update_reference: entity"), "{not_a_reference}");
        assert!(not_a_reference.ids().is_empty());
        let itself = sk_refusal(boss.reference(&boss, o));
        assert!(itself.message().contains("cannot reference itself"), "{itself}");
    }

    #[test]
    fn a_sketch_comes_from_a_profile_and_keeps_its_tangents() {
        if !kernel_present() {
            return;
        }
        let slot = Profile::slot([0.0, 0.0], 60.0, 8.0).unwrap();
        let s = Sketch::from_profile(&slot, true, 1e-9).unwrap();
        let mut tangents = 0;
        for c in s.constraints().unwrap() {
            if s.constraint_kind(c).unwrap() == "tangent" {
                tangents += 1;
                assert!(s.is_joint_tangent(c), "tangent {c} is not a joint tangent");
            }
        }
        assert_eq!(tangents, 4);
        assert_eq!(s.diagnose().unwrap().free, 4);
    }

    #[test]
    fn a_sketch_reads_back_what_it_holds() {
        if !kernel_present() {
            return;
        }
        let s = Sketch::new().unwrap();
        let (a, b) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(10.0, 0.0).unwrap());
        let line = s.add_line(a, b).unwrap();
        assert_eq!((s.kind(a).unwrap(), s.kind(line).unwrap()), ("point", "line"));
        assert_eq!(s.entities().unwrap(), sk_sorted(&[a, b, line]));
        assert_eq!(s.ends(line).unwrap(), [a, b]);
        let c = s.add_circle(s.add_point(0.0, 20.0).unwrap(), 3.0).unwrap();
        assert_eq!(s.kind(c).unwrap(), "circle");
        assert_eq!(s.radius(c).unwrap(), 3.0);
        assert_eq!(s.kind(s.centre(c).unwrap()).unwrap(), "point");
        s.set_radius(c, 4.0).unwrap();
        assert_eq!(s.radius(c).unwrap(), 4.0);
        s.set_point(b, 12.0, 0.0).unwrap();
        assert_eq!(s.point(b).unwrap(), [12.0, 0.0]);
        s.set_construction(c, true).unwrap();
        assert!(s.is_construction(c) && !s.is_reference(c));
        let h = s.horizontal(a, b).unwrap();
        assert_eq!(s.constraint_kind(h).unwrap(), "horizontal");
        assert_eq!(s.constraint_refs(h).unwrap(), [a, b]);
        assert_eq!(s.constraint_value(h).unwrap(), None);
        assert!(!s.constraint_driving(h).unwrap());
        assert_eq!(s.constraint_sense(h).unwrap(), "auto");
        let d = s.distance(a, b, 15.0, false).unwrap();
        assert_eq!(s.constraint_value(d).unwrap(), Some(15.0));
        assert!(!s.constraint_driving(d).unwrap());
        assert!((s.measure(d).unwrap() - 12.0).abs() <= 1e-12);
        let report = s.set_driving(d, true).unwrap();
        assert!(report.converged() && s.constraint_driving(d).unwrap());
        assert_eq!(s.constraint_value(d).unwrap(), Some(12.0));
        let report = s.set_value(d, 20.0).unwrap();
        assert!(report.converged() && (s.measure(d).unwrap() - 20.0).abs() <= 1e-9);
        let report = s.drag(&[(b, [25.0, 5.0])]).unwrap();
        assert!(["converged", "conflicting", "diverged"].contains(&report.status), "{report:?}");
        assert_eq!(s.constraints().unwrap(), sk_sorted(&[h, d]));
        s.remove(h).unwrap();
        assert_eq!(s.constraints().unwrap(), [d]);
        assert_eq!(s.remove_entity(line).unwrap(), [d]);
        assert!(!s.entities().unwrap().contains(&a) && s.constraints().unwrap().is_empty());
        let bez = s.add_bezier(s.add_point(0.0, 0.0).unwrap(), [1.0, 1.0], [2.0, 1.0], [3.0, 0.0]).unwrap();
        assert_eq!(s.kind(bez).unwrap(), "free_curve");
        assert_eq!(s.ends(bez).unwrap().len(), 4);
        assert_eq!(s.open_chains(1e-9).unwrap().len(), 1);
        assert!(sk_refusal(s.kind(9999)).message().contains("sketch_kind"));
        let sideways = sk_refusal(s.tangent(bez, c, "sideways"));
        assert!(
            sideways.message().starts_with("tangent: sense must be one of ") && sideways.message().ends_with(", not 'sideways'"),
            "{sideways}"
        );
    }

    #[test]
    fn a_sketch_tangent_at_end_reads_its_end_back() {
        if !kernel_present() {
            return;
        }
        let s = Sketch::new().unwrap();
        let (a, b) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(4.0, 0.0).unwrap());
        let line = s.add_line(a, b).unwrap();
        let bez = s.add_bezier(b, [5.0, 0.0], [6.0, 1.0], [7.0, 1.0]).unwrap();
        assert_eq!(s.constraint_end(s.tangent_at_end(bez, line, "end").unwrap()).unwrap(), "end");
        assert_eq!(s.constraint_end(s.tangent_at_end(bez, line, "start").unwrap()).unwrap(), "start");
        assert_eq!(s.constraint_end(s.length(line, 4.0, true).unwrap()).unwrap(), "start");
        let unknown = sk_refusal(s.constraint_end(999));
        assert!(unknown.message().contains("sketch_constraint_end: no constraint 999"), "{unknown}");
        let middle = sk_refusal(s.tangent_at_end(bez, line, "middle"));
        assert!(middle.message().contains("tangent_at_end: end must be one of 'start', 'end', not 'middle'"), "{middle}");
    }

    #[test]
    fn a_sketch_checks_nurbs_weights_and_finite_points() {
        if !kernel_present() {
            return;
        }
        let s = Sketch::new().unwrap();
        let start = s.add_point(0.0, 0.0).unwrap();
        let points = [[1.0, 2.0], [3.0, 2.0], [4.0, 0.0]];
        let knots = [0.0, 0.0, 0.0, 0.5, 1.0, 1.0, 1.0];
        let short = sk_refusal(s.add_nurbs(start, &points, &knots, 2, Some(&[1.0, 1.0, 1.0])));
        assert_eq!(
            short.message(),
            "sketch_add_nurbs: 3 weights for 4 control points (the start and 3 given); give one per point"
        );
        let curve = s.add_nurbs(start, &points, &knots, 2, Some(&[1.0, 0.5, 0.5, 1.0])).unwrap();
        let ends = s.ends(curve).unwrap();
        assert_eq!(s.kind(curve).unwrap(), "free_curve");
        assert!(ends.len() == 4 && ends[0] == start, "{ends:?}");
        let plain = s.add_nurbs(start, &points, &knots, 2, None).unwrap();
        assert_eq!(s.kind(plain).unwrap(), "free_curve");

        let fresh = Sketch::new().unwrap();
        let nan = sk_refusal(fresh.add_point(f64::NAN, 0.0));
        assert!(nan.message().starts_with("sketch_add_point: the coordinates must be finite"), "{nan}");
        assert!(sk_refusal(fresh.add_point(0.0, f64::INFINITY)).message().contains("sketch_add_point"));
        assert!(fresh.entities().unwrap().is_empty(), "a refused point was kept");
    }

    #[test]
    fn a_sketch_reader_whose_failure_is_ambiguous_refuses_an_unknown_id() {
        if !kernel_present() {
            return;
        }
        let s = Sketch::new().unwrap();
        let (a, b) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(10.0, 0.0).unwrap());
        let h = s.horizontal(a, b).unwrap();
        // A constraint without a value reads as none; an unknown id is refused, with no ids.
        assert_eq!(s.constraint_value(h).unwrap(), None);
        assert!(!s.constraint_driving(h).unwrap());
        let no_value = sk_refusal(s.constraint_value(999));
        assert!(no_value.message().contains("sketch_constraint_value") && no_value.ids().is_empty(), "{no_value}");
        let no_driving = sk_refusal(s.constraint_driving(999));
        assert!(no_driving.message().contains("sketch_constraint_driving") && no_driving.ids().is_empty(), "{no_driving}");
    }

    #[test]
    fn a_sketch_distance_sense_puts_the_point_on_its_own_side() {
        if !kernel_present() {
            return;
        }
        for (sense, want) in [("positive", 3.0), ("negative", -3.0)] {
            let s = Sketch::new().unwrap();
            let (la, lb) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(10.0, 0.0).unwrap());
            let line = s.add_line(la, lb).unwrap();
            s.fix(la).unwrap();
            s.fix(lb).unwrap();
            let pt = s.add_point(5.0, 1.0).unwrap();
            let dc = s.point_line_distance(pt, line, 3.0, true, sense).unwrap();
            assert_eq!(s.constraint_sense(dc).unwrap(), sense);
            assert!(s.solve().unwrap().converged(), "the {sense} distance did not converge");
            let p = s.point(pt).unwrap();
            assert!((p[1] - want).abs() <= 1e-6, "the {sense} sense put the point at {p:?}");
        }
    }

    #[test]
    fn a_drag_goes_in_ascending_id_order_and_a_repeated_point_is_refused() {
        let moves: Vec<(u32, [f64; 2])> = (0..64u32).map(|i| (i * 37 % 101, [f64::from(i * 37 % 101), -1.0])).collect();
        let (points, xy) = sketch_moves(&moves).unwrap();
        assert!(points.windows(2).all(|w| w[0] < w[1]), "the moves went as {points:?}");
        for (i, id) in points.iter().enumerate() {
            assert_eq!([xy[2 * i], xy[2 * i + 1]], [f64::from(*id), -1.0], "point {id} lost its target");
        }
        let twice = sketch_moves(&[(4, [0.0, 0.0]), (9, [1.0, 1.0]), (4, [2.0, 2.0])]).unwrap_err();
        assert_eq!(twice.message(), "sketch_drag: point 4 given twice");
        assert!(twice.ids().is_empty());
        if !kernel_present() {
            return;
        }
        let (s, corners, _) = sk_rect();
        let refused = sk_refusal(s.drag(&[(corners[2], [1.0, 1.0]), (corners[2], [2.0, 2.0])]));
        assert_eq!(refused.message(), format!("sketch_drag: point {} given twice", corners[2]));
        assert_eq!(s.point(corners[2]).unwrap(), [40.0, 30.0], "a refused drag moved the point");
        let report = s.drag(&[(corners[2], [42.0, 33.0]), (corners[0], [1.0, 1.0])]).unwrap();
        assert!(report.converged(), "{report:?}");
    }

    #[test]
    fn a_sketch_lists_a_redundant_constraint_as_redundant_not_conflicting() {
        if !kernel_present() {
            return;
        }
        let (s, corners, sides) = sk_rect();
        s.fix(corners[0]).unwrap();
        s.length(sides[0], 40.0, true).unwrap();
        s.length(sides[1], 30.0, true).unwrap();
        let h = s.horizontal(corners[3], corners[2]).unwrap();
        assert_eq!(h, 7);
        let dof = s.diagnose().unwrap();
        assert_eq!((dof.free, dof.state), (0, "full"), "{dof:?}");
        assert_eq!(dof.redundant, [7]);
        assert!(dof.conflicting.is_empty(), "{dof:?}");
        assert_eq!(dof.parts.len(), 1, "{dof:?}");
        let part = &dof.parts[0];
        assert_eq!((part.free, part.state), (0, "full"), "{part:?}");
        assert_eq!(part.redundant, [7]);
        assert!(part.conflicting.is_empty(), "{part:?}");
        assert_eq!(part.constraints, [0, 1, 2, 3, 5, 6, 7]);
    }

    #[test]
    fn a_sketch_refuses_an_edit_the_solve_cannot_reach_and_names_its_constraints() {
        if !kernel_present() {
            return;
        }
        let s = Sketch::new().unwrap();
        let (a, b, c) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(1.0, 0.0).unwrap(), s.add_point(0.0, 1.0).unwrap());
        s.distance(a, b, 1.0, true).unwrap();
        s.distance(b, c, 1.0, true).unwrap();
        let d3 = s.distance(a, c, 1.0, true).unwrap();
        let diverged = sk_refusal(s.set_value(d3, 10.0));
        assert!(diverged.message().starts_with("sketch_set_value: the solve did not converge"), "{diverged}");
        assert_eq!(diverged.ids(), [2, 0, 1]);
        assert!(s.solve().unwrap().converged(), "the sketch was left unsolvable");
    }

    /// The fixture every constraint method runs on, fresh each time.
    struct SkEvery {
        s: Sketch,
        a: u32,
        b: u32,
        l1: u32,
        c: u32,
        d: u32,
        l2: u32,
        e: u32,
        c1: u32,
        f: u32,
        c2: u32,
        bz: u32,
    }

    impl SkEvery {
        fn new() -> SkEvery {
            let s = Sketch::new().unwrap();
            let (a, b) = (s.add_point(0.0, 0.0).unwrap(), s.add_point(10.0, 0.0).unwrap());
            let l1 = s.add_line(a, b).unwrap();
            let (c, d) = (s.add_point(0.0, 5.0).unwrap(), s.add_point(10.0, 6.0).unwrap());
            let l2 = s.add_line(c, d).unwrap();
            let e = s.add_point(30.0, 0.0).unwrap();
            let c1 = s.add_circle(e, 5.0).unwrap();
            let f = s.add_point(30.0, 20.0).unwrap();
            let c2 = s.add_circle(f, 3.0).unwrap();
            let g = s.add_point(50.0, 0.0).unwrap();
            let bz = s.add_bezier(g, [51.0, 1.0], [52.0, 1.0], [53.0, 0.0]).unwrap();
            SkEvery { s, a, b, l1, c, d, l2, e, c1, f, c2, bz }
        }

        fn pt(&self, id: u32) -> [f64; 2] {
            self.s.point(id).unwrap()
        }

        fn gap(&self, p: u32, q: u32) -> f64 {
            let (p, q) = (self.pt(p), self.pt(q));
            (q[0] - p[0]).hypot(q[1] - p[1])
        }

        fn dir(&self, line: u32) -> [f64; 2] {
            let ends = self.s.ends(line).unwrap();
            let (p, q) = (self.pt(ends[0]), self.pt(ends[1]));
            [q[0] - p[0], q[1] - p[1]]
        }

        /// How far `p` is from the line through `line`.
        fn off_line(&self, p: [f64; 2], line: u32) -> f64 {
            let o = self.pt(self.s.ends(line).unwrap()[0]);
            let u = self.dir(line);
            sk_cross(u, [p[0] - o[0], p[1] - o[1]]).abs() / sk_norm(u)
        }

        fn r(&self, circle: u32) -> f64 {
            self.s.radius(circle).unwrap()
        }
    }

    fn sk_cross(u: [f64; 2], v: [f64; 2]) -> f64 {
        u[0] * v[1] - u[1] * v[0]
    }

    fn sk_dot(u: [f64; 2], v: [f64; 2]) -> f64 {
        u[0] * v[0] + u[1] * v[1]
    }

    fn sk_norm(u: [f64; 2]) -> f64 {
        u[0].hypot(u[1])
    }

    fn sk_near(u: f64, v: f64) -> bool {
        (u - v).abs() <= 1e-6
    }

    type SkCall = fn(&SkEvery) -> Result<u32>;
    type SkRefs = fn(&SkEvery) -> Vec<u32>;
    type SkHolds = fn(&SkEvery) -> bool;

    #[test]
    fn a_sketch_holds_every_constraint_method_with_its_kind_refs_and_value() {
        if !kernel_present() {
            return;
        }
        // kind, value (None: a geometric kind), the call, its refs in order, and the geometry it
        // leaves -- so a kind sent under another kind's code is caught though it reads back as sent.
        let rows: [(&str, Option<f64>, SkCall, SkRefs, SkHolds); 27] = [
            ("coincident", None, |x| x.s.coincident(x.a, x.c), |x| vec![x.a, x.c], |x| x.gap(x.a, x.c) <= 1e-6),
            ("point_on_line", None, |x| x.s.point_on_line(x.c, x.l1), |x| vec![x.c, x.l1], |x| sk_near(x.off_line(x.pt(x.c), x.l1), 0.0)),
            ("point_on_circle", None, |x| x.s.point_on_circle(x.a, x.c1), |x| vec![x.a, x.c1], |x| sk_near(x.gap(x.a, x.e), x.r(x.c1))),
            ("horizontal", None, |x| x.s.horizontal(x.c, x.d), |x| vec![x.c, x.d], |x| {
                sk_near(x.pt(x.c)[1], x.pt(x.d)[1]) && x.gap(x.c, x.d) > 1.0
            }),
            ("vertical", None, |x| x.s.vertical(x.a, x.c), |x| vec![x.a, x.c], |x| {
                sk_near(x.pt(x.a)[0], x.pt(x.c)[0]) && x.gap(x.a, x.c) > 1.0
            }),
            ("parallel", None, |x| x.s.parallel(x.l1, x.l2), |x| vec![x.l1, x.l2], |x| {
                let (u, v) = (x.dir(x.l1), x.dir(x.l2));
                sk_near(sk_cross(u, v) / (sk_norm(u) * sk_norm(v)), 0.0)
            }),
            ("perpendicular", None, |x| x.s.perpendicular(x.l1, x.l2), |x| vec![x.l1, x.l2], |x| {
                let (u, v) = (x.dir(x.l1), x.dir(x.l2));
                sk_near(sk_dot(u, v) / (sk_norm(u) * sk_norm(v)), 0.0)
            }),
            ("collinear", None, |x| x.s.collinear(x.l1, x.l2), |x| vec![x.l1, x.l2], |x| {
                sk_near(x.off_line(x.pt(x.c), x.l1), 0.0) && sk_near(x.off_line(x.pt(x.d), x.l1), 0.0)
            }),
            ("tangent", None, |x| x.s.tangent(x.l2, x.c1, "auto"), |x| vec![x.l2, x.c1], |x| sk_near(x.off_line(x.pt(x.e), x.l2), x.r(x.c1))),
            ("tangent_at_end", None, |x| x.s.tangent_at_end(x.bz, x.l1, "end"), |x| vec![x.bz, x.l1], |x| {
                let poles = x.s.ends(x.bz).unwrap();
                let (p, q) = (x.pt(poles[2]), x.pt(poles[3]));
                let (u, v) = ([q[0] - p[0], q[1] - p[1]], x.dir(x.l1));
                sk_near(sk_cross(u, v) / (sk_norm(u) * sk_norm(v)), 0.0)
            }),
            ("concentric", None, |x| x.s.concentric(x.c1, x.c2), |x| vec![x.c1, x.c2], |x| x.gap(x.e, x.f) <= 1e-6),
            ("equal_length", None, |x| x.s.equal_length(x.l1, x.l2), |x| vec![x.l1, x.l2], |x| sk_near(sk_norm(x.dir(x.l1)), sk_norm(x.dir(x.l2)))),
            ("equal_radius", None, |x| x.s.equal_radius(x.c1, x.c2), |x| vec![x.c1, x.c2], |x| sk_near(x.r(x.c1), x.r(x.c2))),
            ("midpoint", None, |x| x.s.midpoint(x.c, x.l1), |x| vec![x.c, x.l1], |x| {
                let (a, b, c) = (x.pt(x.a), x.pt(x.b), x.pt(x.c));
                sk_near(c[0], (a[0] + b[0]) / 2.0) && sk_near(c[1], (a[1] + b[1]) / 2.0)
            }),
            ("symmetric", None, |x| x.s.symmetric(x.c, x.d, x.l1), |x| vec![x.c, x.d, x.l1], |x| {
                let (c, d) = (x.pt(x.c), x.pt(x.d));
                let (mid, cd, u) = ([(c[0] + d[0]) / 2.0, (c[1] + d[1]) / 2.0], [d[0] - c[0], d[1] - c[1]], x.dir(x.l1));
                sk_near(x.off_line(mid, x.l1), 0.0) && sk_near(sk_dot(cd, u) / (sk_norm(cd) * sk_norm(u)), 0.0)
            }),
            ("fix", None, |x| x.s.fix(x.a), |x| vec![x.a], |x| {
                x.s.drag(&[(x.a, [3.0, 3.0])]).unwrap();
                sk_norm(x.pt(x.a)) <= 1e-9
            }),
            ("distance", Some(12.0), |x| x.s.distance(x.a, x.d, 12.0, true), |x| vec![x.a, x.d], |x| sk_near(x.gap(x.a, x.d), 12.0)),
            ("point_line_distance", Some(4.0), |x| x.s.point_line_distance(x.c, x.l1, 4.0, true, "auto"), |x| vec![x.c, x.l1], |x| {
                sk_near(x.off_line(x.pt(x.c), x.l1), 4.0)
            }),
            // measured from b's start
            ("line_distance", Some(4.0), |x| x.s.line_distance(x.l1, x.l2, 4.0, true, "auto"), |x| vec![x.l1, x.l2], |x| {
                sk_near(x.off_line(x.pt(x.c), x.l1), 4.0)
            }),
            ("circle_line_distance", Some(7.0), |x| x.s.circle_line_distance(x.c1, x.l1, 7.0, true, "auto"), |x| vec![x.c1, x.l1], |x| {
                sk_near(x.off_line(x.pt(x.e), x.l1) - x.r(x.c1), 7.0)
            }),
            ("circle_distance", Some(9.0), |x| x.s.circle_distance(x.c1, x.c2, 9.0, true), |x| vec![x.c1, x.c2], |x| {
                sk_near(x.gap(x.e, x.f) - x.r(x.c1) - x.r(x.c2), 9.0)
            }),
            ("horizontal_distance", Some(8.0), |x| x.s.horizontal_distance(x.a, x.d, 8.0, true), |x| vec![x.a, x.d], |x| {
                sk_near((x.pt(x.d)[0] - x.pt(x.a)[0]).abs(), 8.0)
            }),
            ("vertical_distance", Some(4.0), |x| x.s.vertical_distance(x.a, x.d, 4.0, true), |x| vec![x.a, x.d], |x| {
                sk_near((x.pt(x.d)[1] - x.pt(x.a)[1]).abs(), 4.0)
            }),
            ("length", Some(12.0), |x| x.s.length(x.l1, 12.0, true), |x| vec![x.l1], |x| sk_near(sk_norm(x.dir(x.l1)), 12.0)),
            ("angle", Some(0.5), |x| x.s.angle(x.l1, x.l2, 0.5, true), |x| vec![x.l1, x.l2], |x| {
                let (u, v) = (x.dir(x.l1), x.dir(x.l2));
                sk_near(sk_cross(u, v).atan2(sk_dot(u, v)).abs(), 0.5)
            }),
            ("radius", Some(6.0), |x| x.s.radius_of(x.c1, 6.0, true), |x| vec![x.c1], |x| sk_near(x.r(x.c1), 6.0)),
            ("diameter", Some(8.0), |x| x.s.diameter(x.c1, 8.0, true), |x| vec![x.c1], |x| sk_near(x.r(x.c1), 4.0)),
        ];
        for (kind, value, call, refs, holds) in rows {
            let x = SkEvery::new();
            let id = call(&x).unwrap_or_else(|e| panic!("the {kind} was refused: {e}"));
            assert_eq!(x.s.constraint_kind(id).unwrap(), kind);
            assert_eq!(x.s.constraint_refs(id).unwrap(), refs(&x), "the {kind}'s refs");
            assert_eq!(x.s.constraint_value(id).unwrap(), value, "the {kind}'s value");
            assert!(holds(&x), "the {kind} does not hold in the geometry");
        }
        let x = SkEvery::new();
        let (h, i, j) = (x.s.add_point(70.0, 0.0).unwrap(), x.s.add_point(75.0, 0.0).unwrap(), x.s.add_point(70.0, 5.0).unwrap());
        let arc = x.s.add_arc(h, i, j).unwrap();
        assert_eq!(x.s.kind(arc).unwrap(), "arc");
        assert_eq!(x.s.centre(arc).unwrap(), h);
        assert_eq!(x.s.ends(arc).unwrap(), [i, j]);
        let k = x.s.add_point(90.0, 0.0).unwrap();
        let conic = x.s.add_conic(k, [91.0, 1.0], [92.0, 0.0], 0.7).unwrap();
        assert_eq!(x.s.kind(conic).unwrap(), "free_curve");
        let ends = x.s.ends(conic).unwrap();
        assert!(ends.len() == 3 && ends[0] == k, "{ends:?}");
    }

    // ---- the health report and healing (healing in the other wrappers, 2026-10-29) ------

    use crate::Cracks;

    fn rel(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol * b.abs().max(f64::MIN_POSITIVE)
    }

    #[test]
    fn health_of_a_closed_cuboid_has_nothing_free_and_cracks_only_on_request() {
        if !kernel_present() {
            return;
        }
        let cube = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let report = cube.health(None, false).unwrap();
        assert!(report.free_edges.is_empty() && report.wires.is_empty() && report.small.is_empty());
        assert_eq!(report.cracks, None);
        assert!(rel(report.extent, 10.0 * 3f64.sqrt(), 1e-12), "{}", report.extent);
        assert!(rel(report.rounding, 1e-7 * report.extent, 1e-12));
        assert!(rel(report.tolerance, 1e-4 * report.extent, 1e-12));
        assert_eq!(
            (report.loose_edges, report.worst_loose, report.sew_pairs, report.sew_refused, report.sew_worst_gap),
            (0, 0.0, 0, 0, 0.0)
        );
        let cracks = cube.health(None, true).unwrap().cracks.expect("cracks were asked for");
        assert_eq!(cracks, Cracks { watertight: true, open: 0, folded: 0, crossings: 0, edges: vec![] });
        assert_eq!(cube.health(Some(0.5), false).unwrap().tolerance, 0.5);
        assert_eq!(cube.health(Some(-1.0), false).unwrap().tolerance, report.tolerance);
    }

    #[test]
    fn health_of_a_cuboid_without_a_face_is_one_open_rim_of_four_edges() {
        if !kernel_present() {
            return;
        }
        let hole = Solid::cuboid(10.0, 10.0, 10.0).unwrap().drop_faces(&[0]).unwrap();
        let report = hole.health(None, false).unwrap();
        assert_eq!((report.free_edges.len(), report.wires.len()), (4, 1));
        let wire = &report.wires[0];
        assert_eq!((wire.first, wire.count, wire.closed), (0, 4, true));
        assert!(rel(wire.length, 40.0, 1e-9), "{}", wire.length);
        assert_eq!(report.wire_edges(0), &report.free_edges[..]);
        let rows: Vec<_> = report.free_edges.iter().map(|e| (e.trim, e.edge, e.face, e.partner)).collect();
        assert_eq!(
            rows,
            [(4, Some(3), 1, Some(2)), (16, Some(2), 4, Some(3)), (11, Some(1), 2, Some(0)), (15, Some(0), 3, Some(1))]
        );
        for e in &report.free_edges {
            assert_eq!((e.wire, e.shared_ends), (0, 0));
            assert!(rel(e.length, 10.0, 1e-9) && rel(e.gap, 10.0, 1e-9), "{e:?}");
        }
        assert!(rel(report.worst_gap, 10.0, 1e-9));
        assert_eq!((report.sew_pairs, report.sew_refused, report.sew_worst_gap, report.loose_edges), (0, 0, 0.0, 0));
        let cracks = hole.health(None, true).unwrap().cracks.expect("cracks were asked for");
        assert_eq!(cracks, Cracks { watertight: false, open: 0, folded: 0, crossings: 0, edges: vec![] });
    }

    #[test]
    fn health_lists_a_thin_plate_s_small_features_by_kind_index_and_size() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 0.001).unwrap();
        let report = plate.health(Some(0.01), false).unwrap();
        let got: Vec<_> = report.small.iter().map(|s| (s.kind.as_str(), s.index)).collect();
        let want: Vec<_> = [8, 9, 10, 11].map(|i| ("short_edge", i)).into_iter().chain([2, 3, 4, 5].map(|i| ("sliver_face", i))).collect();
        assert_eq!(got, want);
        assert!(report.small[..4].iter().all(|s| rel(s.size, 0.001, 1e-9)), "{:?}", report.small);
        assert!(report.small[4..].iter().all(|s| rel(s.size, 0.0009999, 1e-3)), "{:?}", report.small);
    }

    #[test]
    fn health_reports_a_tiny_body_and_its_tiny_faces() {
        if !kernel_present() {
            return;
        }
        let tiny = Solid::cuboid(0.0005, 0.0005, 0.0005).unwrap();
        let report = tiny.health(Some(0.01), false).unwrap();
        let of = |kind: &str| report.small.iter().filter(|s| s.kind == kind).collect::<Vec<_>>();
        assert_eq!((of("short_edge").len(), of("tiny_face").len(), of("tiny_body").len(), report.small.len()), (12, 6, 1, 19));
        assert_eq!(of("tiny_face").iter().map(|s| s.index).collect::<Vec<_>>(), [0, 1, 2, 3, 4, 5]);
        assert!(of("tiny_face").iter().all(|s| rel(s.size, 2.5e-7, 1e-9)));
        let body = of("tiny_body")[0];
        assert_eq!(body.index, 0);
        assert!(rel(body.size, 0.0005 * 3f64.sqrt(), 1e-9), "{}", body.size);
    }

    #[test]
    fn healed_cuboid_heals_to_itself_as_a_new_solid() {
        if !kernel_present() {
            return;
        }
        let cube = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
        let (healed, report) = cube.healed(None, HealKinds::default()).unwrap();
        assert_ne!(healed.raw(), cube.raw());
        assert!(report.fixes.is_empty() && report.refused.is_empty() && !report.guarded);
        assert_eq!((report.small_before, report.small_after, report.free_before, report.free_after), (0, 0, 0, 0));
        assert!(report.closed_before && report.closed_after);
        assert_eq!((report.nonmanifold_before, report.nonmanifold_after), (0, 0));
        assert!(rel(report.tolerance, cube.health(None, false).unwrap().tolerance, 1e-12));
        assert_eq!(report.moved, 0.0);
        assert_eq!(healed.faces().unwrap(), 6);
        assert!(rel(healed.mass(0.0).unwrap().volume, 1000.0, 1e-9));
        assert_eq!(cube.healed(Some(0.5), HealKinds::default()).unwrap().1.tolerance, 0.5);
        let tolerances: Vec<_> = (0..12).map(|e| healed.edge_tolerance(e).unwrap()).collect();
        assert_eq!(tolerances, vec![Some(0.0); 12]);
        assert_eq!(healed.edge_tolerance(0xFFFF_FFF0).unwrap(), None);
    }

    #[test]
    fn healed_with_every_kind_off_refuses_each_small_feature_as_toggled() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 0.001).unwrap();
        let off = HealKinds { edges: false, faces: false, holes: false };
        let (_, report) = plate.healed(Some(0.01), off).unwrap();
        assert!(report.fixes.is_empty());
        assert_eq!((report.small_before, report.small_after), (8, 8));
        let got: Vec<_> = report.refused.iter().map(|r| (r.kind.as_str(), r.index, r.why.as_str(), r.figure)).collect();
        let want: Vec<_> = [8, 9, 10, 11]
            .map(|i| ("short_edge", i, "toggled", 0.0))
            .into_iter()
            .chain([2, 3, 4, 5].map(|i| ("sliver_face", i, "toggled", 0.0)))
            .collect();
        assert_eq!(got, want);
        let (_, on) = plate.healed(Some(0.01), HealKinds::default()).unwrap();
        assert_eq!(on.small_before, 8);
        assert!(on.refused.iter().all(|r| r.why != "toggled"));
        assert!(!on.guarded || on.refused.iter().all(|r| r.why == "body_guard"));
        // every switch but holes: still nothing toggled (the plate has no hole to switch off)
        let (_, no_holes) = plate.healed(Some(0.01), HealKinds { holes: false, ..HealKinds::default() }).unwrap();
        assert!(no_holes.refused.iter().all(|r| r.why != "toggled"));
    }

    // ---- wall thickness -------------------------------------------------------------

    /// The face of body `body` whose reading at `p` lies at `p`.
    fn thickness_face_holding(gauge: &ThicknessGauge, solid: &Solid, body: u32, p: [f64; 3]) -> u32 {
        for f in 0..solid.faces().unwrap() {
            if let Some(r) = gauge.thickness_at(body, f, p, 100.0, 0.5).unwrap() {
                if r.point.iter().zip(p).all(|(a, b)| (a - b).abs() < 1e-9) {
                    return f;
                }
            }
        }
        panic!("no face holds {p:?}");
    }

    fn thickness_tube() -> Solid {
        let ring = Profile::circle(5.0).unwrap().with_hole(&Profile::circle(4.0).unwrap()).unwrap();
        Solid::extrude(&ring, &Frame::XY, 10.0).unwrap()
    }

    const THICKNESS_LOWER: ([[f64; 3]; 3], [[u32; 3]; 1]) = ([[0.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]], [[0, 1, 2]]);
    const THICKNESS_UPPER: ([[f64; 3]; 3], [[u32; 3]; 1]) = ([[0.0, 0.0, 1.0], [1.0, 0.0, 1.0], [0.0, 1.0, 1.0]], [[0, 1, 2]]);

    #[test]
    fn thickness_structs_have_the_headers_layout() {
        use std::mem::{offset_of, size_of};
        type T = sys::CadaclysmBlacksmithThickness;
        let offsets = [
            offset_of!(T, body),
            offset_of!(T, vertex),
            offset_of!(T, face),
            offset_of!(T, point),
            offset_of!(T, thickness),
            offset_of!(T, opposite),
            offset_of!(T, opposite_body),
            offset_of!(T, opposite_face),
            offset_of!(T, knife),
            offset_of!(T, exact_thickness),
            offset_of!(T, exact_opposite),
            offset_of!(T, sphere),
        ];
        assert_eq!(offsets, [0, 4, 8, 16, 40, 48, 72, 76, 80, 88, 96, 120]);
        assert_eq!(size_of::<T>(), 128);
        type M = sys::CadaclysmBlacksmithMeshThickness;
        let offsets = [
            offset_of!(M, mesh),
            offset_of!(M, vertex),
            offset_of!(M, thickness),
            offset_of!(M, point),
            offset_of!(M, opposite),
            offset_of!(M, opposite_mesh),
            offset_of!(M, opposite_triangle),
            offset_of!(M, knife),
        ];
        assert_eq!(offsets, [0, 4, 8, 16, 40, 64, 68, 72]);
        assert_eq!(size_of::<M>(), 80);
        type F = sys::CadaclysmBlacksmithFaceThickness;
        let offsets = [offset_of!(F, found), offset_of!(F, thickness), offset_of!(F, min), offset_of!(F, max), offset_of!(F, uniform)];
        assert_eq!(offsets, [0, 8, 16, 24, 32]);
        assert_eq!(size_of::<F>(), 40);
        type G = sys::CadaclysmBlacksmithThicknessMesh;
        let offsets = [
            offset_of!(G, positions),
            offset_of!(G, normals),
            offset_of!(G, indices),
            offset_of!(G, faces),
            offset_of!(G, vertex_count),
            offset_of!(G, triangle_count),
        ];
        assert_eq!(offsets, [0, 8, 16, 24, 32, 36]);
        assert_eq!(size_of::<G>(), 40);
    }

    #[test]
    fn thickness_a_plate_reads_two_at_every_cap_vertex() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        let gauge = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        assert_eq!(gauge.body_count(), 1);
        assert_eq!(gauge.tolerance(), 0.01);
        let rows = gauge.thickness(10.0, 0.5).unwrap();
        let mesh = gauge.mesh(0).unwrap();
        let caps: Vec<&Thickness> =
            rows.iter().filter(|r| (r.point[2].abs() - 1.0).abs() < 1e-9 && (r.opposite[2] + r.point[2]).abs() < 1e-9).collect();
        assert!(caps.len() >= 8, "{rows:?}");
        for r in &caps {
            near(r.thickness, 2.0, 1e-9, "thickness");
            near(r.exact_thickness, 2.0, 1e-9, "exact thickness");
            near(r.exact_opposite[2], -r.point[2], 1e-9, "exact opposite");
            assert!(!r.knife && r.opposite_body == 0, "{r:?}");
        }
        for r in &rows {
            assert_eq!(r.body, 0);
            let v = r.vertex.expect("a mesh reading names its vertex") as usize;
            assert_eq!(mesh.positions[v], r.point, "{r:?}");
            assert!(r.sphere.is_none_or(|s| s.is_finite()));
        }
        // below the wall nothing reads
        assert!(gauge.thickness(1.0, 0.0).unwrap().is_empty());
        assert_eq!(gauge.thickness(10.0, 0.0).unwrap().len(), rows.len());
    }

    #[test]
    fn thickness_gauge_mesh_is_a_copy_that_matches_the_readings() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        let gauge = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let m = gauge.mesh(0).unwrap();
        assert!(m.faces.len() == m.triangles.len() && m.triangles.len() >= 12);
        assert!(!m.positions.is_empty() && m.normals.len() == m.positions.len());
        let faces = plate.faces().unwrap();
        assert!(m.faces.iter().all(|&f| f < faces));
        assert!(m.triangles.iter().flatten().all(|&k| (k as usize) < m.positions.len()));
        for n in &m.normals {
            near((n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt(), 1.0, 1e-9, "unit normal");
        }
        let rows = gauge.thickness(100.0, 0.5).unwrap();
        assert_eq!(rows.len(), m.positions.len());
        for r in &rows {
            let v = r.vertex.unwrap();
            let t = m.triangles.iter().position(|tri| tri.contains(&v)).unwrap();
            assert_eq!(m.faces[t], r.face, "{r:?}");
        }
        assert!(message(gauge.mesh(1)).starts_with("thickness_gauge_mesh: no body 1 -- there are 1"));
        // copied out: the mesh outlives the gauge
        drop(gauge);
        assert_eq!(m.positions.len(), rows.len());
    }

    #[test]
    fn thickness_at_a_point_reads_one_row_with_no_vertex() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        let probe = [1.0, 2.0, 1.0];
        let gauge = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let top = thickness_face_holding(&gauge, &plate, 0, probe);
        let r = gauge.thickness_at(0, top, probe, 100.0, 0.5).unwrap().unwrap();
        assert_eq!(r.vertex, None);
        assert_eq!((r.body, r.face, r.opposite_body), (0, top, 0));
        assert_eq!(r.point, probe);
        near(r.thickness, 2.0, 1e-9, "thickness");
        near(r.exact_thickness, 2.0, 1e-9, "exact thickness");
        near(r.opposite[2], -1.0, 1e-9, "opposite");
        near(r.exact_opposite[2], -1.0, 1e-9, "exact opposite");
        near(r.sphere.expect("a ball under the maximum"), 2.0, 0.02, "sphere");
        // thicker than the maximum: None
        assert_eq!(gauge.thickness_at(0, top, probe, 1.0, 0.5).unwrap(), None);
        // the sharp angle defaults to 0 (the gauge call takes it explicitly)
        near(gauge.thickness_at(0, top, probe, 100.0, 0.0).unwrap().unwrap().thickness, r.thickness, 1e-12, "sharp angle 0");
    }

    #[test]
    fn thickness_at_face_reads_the_plate_and_none_where_nothing_is_found() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        let gauge = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let top = thickness_face_holding(&gauge, &plate, 0, [1.0, 2.0, 1.0]);
        let f = gauge.thickness_at_face(0, top, None, 100.0).unwrap().unwrap();
        near(f.thickness, 2.0, 1e-9, "thickness");
        near(f.min, 2.0, 1e-9, "min");
        near(f.max, 2.0, 1e-9, "max");
        assert!(f.uniform);
        let a = gauge.thickness_at_face(0, top, Some([1.0, 2.0, 5.0]), 100.0).unwrap().unwrap();
        near(a.thickness, 2.0, 1e-9, "thickness at");
        assert!(a.min == a.max && a.uniform, "{a:?}");
        // not found: under the maximum, and off the face
        assert_eq!(gauge.thickness_at_face(0, top, None, 1.0).unwrap(), None);
        assert_eq!(gauge.thickness_at_face(0, top, Some([50.0, 2.0, 5.0]), 100.0).unwrap(), None);
        // the one-body convenience: a gauge of its own
        let s = plate.thickness_at_face(top, None, 100.0, DEFAULT_THICKNESS_TOLERANCE).unwrap().unwrap();
        near(s.thickness, 2.0, 1e-9, "solid thickness");
        assert!(s.uniform);
        let t = plate.thickness_at_face(top, Some([1.0, 2.0, 5.0]), 100.0, 0.05).unwrap().unwrap();
        near(t.thickness, 2.0, 1e-9, "solid thickness at");
        assert_eq!(plate.thickness_at_face(top, None, 1.0, DEFAULT_THICKNESS_TOLERANCE).unwrap(), None);
    }

    #[test]
    fn thickness_a_ball_past_the_maximum_is_none() {
        if !kernel_present() {
            return;
        }
        let wedge = Solid::extrude(&Profile::polygon(&[[0.0, 0.0], [10.0, 0.0], [0.0, 10.0]]).unwrap(), &Frame::XY, 20.0).unwrap();
        let probe = [5.0, 0.0, 10.0];
        let gauge = ThicknessGauge::new(&[&wedge], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let f = thickness_face_holding(&gauge, &wedge, 0, probe);
        let wide = gauge.thickness_at(0, f, probe, 100.0, 0.5).unwrap().unwrap();
        near(wide.sphere.expect("a ball at 100"), 2.0 * 5.0 / (1.0 + 2f64.sqrt()), 0.01, "sphere");
        let narrow = gauge.thickness_at(0, f, probe, 4.0, 0.5).unwrap().unwrap();
        near(narrow.thickness, 5.0 / 2f64.sqrt(), 1e-9, "thickness");
        assert_eq!(narrow.sphere, None, "{narrow:?}");
    }

    #[test]
    fn thickness_two_bodies_read_each_other_and_the_one_shot_agrees() {
        if !kernel_present() {
            return;
        }
        let slab = Solid::extrude(&Profile::polygon(&[[0.0, 0.0], [10.0, 0.0], [10.0, 3.0], [0.0, 1.0]]).unwrap(), &Frame::XY, 4.0).unwrap();
        let tube = thickness_tube();
        let gauge = ThicknessGauge::new(&[&slab, &tube], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        assert_eq!(gauge.body_count(), 2);
        let via = gauge.thickness(100.0, 0.5).unwrap();
        let one = thickness(&[&slab, &tube], 100.0, 0.5, DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let key = |rows: &[Thickness]| rows.iter().map(|r| (r.body, r.vertex, r.face, r.thickness, r.opposite_body)).collect::<Vec<_>>();
        assert_eq!(key(&one), key(&via));
        assert!(one.iter().any(|r| r.body == 0 && r.opposite_body == 1), "the slab reads the tube somewhere");
        assert!(one.iter().any(|r| r.body == 1 && r.opposite_body == 0), "the tube reads the slab somewhere");
        assert!(thickness(&[&slab], 0.001, 0.0, DEFAULT_THICKNESS_TOLERANCE).unwrap().is_empty());
        assert!(!thickness(&[&slab], 100.0, 0.0, 0.05).unwrap().is_empty());
    }

    #[test]
    fn mesh_thickness_two_triangles_one_apart_read_one_across() {
        if !kernel_present() {
            return;
        }
        let (lower, upper) = (THICKNESS_LOWER, THICKNESS_UPPER);
        let meshes: [(&[[f64; 3]], &[[u32; 3]]); 2] = [(&lower.0, &lower.1), (&upper.0, &upper.1)];
        let rows = mesh_thickness(&meshes, 10.0, 0.5).unwrap();
        assert_eq!(rows.len(), 6, "{rows:?}");
        for r in &rows {
            near(r.thickness, 1.0, 1e-12, "thickness");
            assert!(!r.knife, "{r:?}");
            assert_eq!((r.opposite_mesh, r.opposite_triangle), (1 - r.mesh, 0), "{r:?}");
            assert_eq!(r.point, meshes[r.mesh as usize].0[r.vertex as usize], "{r:?}");
            near(r.opposite[2], 1.0 - r.point[2], 1e-12, "opposite z");
            assert_eq!(r.opposite[..2], r.point[..2]);
        }
        assert_eq!(rows.iter().map(|r| (r.mesh, r.vertex)).collect::<Vec<_>>(), [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]);
        // under the gap nothing; no meshes at all, nothing
        assert!(mesh_thickness(&meshes, 0.5, 0.5).unwrap().is_empty());
        assert!(mesh_thickness(&[], 1.0, 0.0).unwrap().is_empty());
    }

    #[test]
    fn thickness_refusals_carry_the_calls_prefix() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        assert!(message(ThicknessGauge::new(&[&plate], -1.0)).starts_with("thickness_gauge_new: the tolerance must be positive and finite"));
        let g = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        let p = [1.0, 2.0, 1.0];
        assert!(message(g.thickness(0.0, 0.0)).starts_with("thickness_gauge_measure: the maximum must be positive and finite"));
        assert!(message(g.thickness(10.0, -0.1)).starts_with("thickness_gauge_measure: the sharp angle must be zero or positive and finite"));
        assert_eq!(message(g.thickness_at(3, 0, p, 10.0, 0.0)), "thickness_gauge_at: no body 3 -- there are 1");
        assert_eq!(message(g.thickness_at(0, 99, p, 10.0, 0.0)), "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)");
        assert!(message(g.thickness_at(0, 0, [1.0, f64::NAN, 1.0], 10.0, 0.0)).starts_with("thickness_gauge_at: the point must be finite"));
        assert_eq!(message(g.thickness_at_face(2, 0, None, 10.0)), "thickness_gauge_face: no body 2 -- there are 1");
        assert_eq!(message(g.thickness_at_face(0, 99, None, 10.0)), "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)");
        assert!(message(g.thickness_at_face(0, 0, Some([f64::INFINITY, 0.0, 1.0]), 10.0)).starts_with("thickness_gauge_face: the point must be finite"));
        assert!(message(g.thickness_at_face(0, 0, None, 0.0)).starts_with("thickness_gauge_face: the maximum must be positive and finite"));
        // the conveniences refuse with the gauge call's own prefix
        assert!(message(thickness(&[&plate], -1.0, 0.0, DEFAULT_THICKNESS_TOLERANCE))
            .starts_with("thickness_gauge_measure: the maximum must be positive and finite"));
        assert!(message(thickness(&[&plate], 10.0, 0.0, f64::INFINITY)).starts_with("thickness_gauge_new: the tolerance must be positive and finite"));
        assert!(message(plate.thickness_at_face(99, None, 10.0, DEFAULT_THICKNESS_TOLERANCE)).starts_with("thickness_gauge_face: no face 99"));
        // mesh_thickness: the kernel's refusals (the types rule out malformed pairs, points and triples)
        let (lower, upper) = (THICKNESS_LOWER, THICKNESS_UPPER);
        let meshes: [(&[[f64; 3]], &[[u32; 3]]); 2] = [(&lower.0, &lower.1), (&upper.0, &upper.1)];
        assert!(message(mesh_thickness(&meshes, 0.0, 0.0)).starts_with("mesh_thickness: the maximum must be positive and finite"));
        assert!(message(mesh_thickness(&meshes, 10.0, -0.5)).starts_with("mesh_thickness: the sharp angle must be zero or positive and finite"));
        let short: [[f64; 3]; 2] = [[0.0; 3], [1.0, 0.0, 0.0]];
        assert!(message(mesh_thickness(&[(&short, &[[0, 1, 2]])], 10.0, 0.0)).starts_with("mesh_thickness: a triangle names a position past the mesh"));
        let bad: [[f64; 3]; 3] = [[0.0; 3], [1.0, f64::NAN, 0.0], [0.0, 1.0, 0.0]];
        assert!(message(mesh_thickness(&[(&bad, &[[0, 1, 2]])], 10.0, 0.0)).starts_with("mesh_thickness: a mesh position is not finite"));
    }

    #[test]
    fn thickness_gauge_answers_on_after_its_solids_are_dropped() {
        if !kernel_present() {
            return;
        }
        let plate = Solid::cuboid(10.0, 10.0, 2.0).unwrap();
        let gauge = ThicknessGauge::new(&[&plate], DEFAULT_THICKNESS_TOLERANCE).unwrap();
        drop(plate);
        let rows = gauge.thickness(10.0, 0.0).unwrap();
        assert!(!rows.is_empty());
        let f = gauge.thickness_at_face(0, rows[0].face, None, 100.0).unwrap();
        assert!(f.is_some());
        assert!(format!("{gauge:?}").starts_with("ThicknessGauge("));
    }

    // ---- transforms (plan A4) -----------------------------------------------------

    mod transforms {
        use super::*;
        use std::f64::consts::{FRAC_PI_2, FRAC_PI_4, FRAC_PI_8, PI};

        const ORIGIN: [f64; 3] = [0.0, 0.0, 0.0];

        fn near(a: &[f64], b: &[f64], tolerance: f64) -> bool {
            a.len() == b.len() && a.iter().zip(b).all(|(x, y)| (x - y).abs() <= tolerance)
        }

        fn assert_near(a: &[f64], b: &[f64], tolerance: f64) {
            assert!(near(a, b, tolerance), "{a:?} is not {b:?} to {tolerance}");
        }

        fn refusal<T: fmt::Debug>(result: Result<T>, prefix: &str) {
            let message = result.expect_err("this should have been refused").message().to_string();
            assert!(message.starts_with(prefix), "{message:?} does not start with {prefix:?}");
        }

        fn fxy() -> Frame {
            Frame::xy(ORIGIN)
        }

        fn det(t: &Transform) -> f64 {
            let r = t.rows();
            r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8]) + r[2] * (r[4] * r[9] - r[5] * r[8])
        }

        #[test]
        fn a_transform_is_sixteen_numbers_row_major_and_composes_right_to_left() {
            if !kernel_present() {
                return;
            }
            let t = Transform::translation([1.0, 2.0, 3.0]).unwrap();
            assert_eq!(t.rows(), [1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 2.0, 0.0, 0.0, 1.0, 3.0, 0.0, 0.0, 0.0, 1.0]);
            let s = Transform::scale(ORIGIN, 2.0).unwrap();
            assert_near(&t.compose(&s).unwrap().point([1.0, 1.0, 1.0]), &[3.0, 4.0, 5.0], 1e-12);
            assert_near(&s.compose(&t).unwrap().point([1.0, 1.0, 1.0]), &[4.0, 6.0, 8.0], 1e-12);
            assert_near(&(t * s).unwrap().point([1.0, 1.0, 1.0]), &[3.0, 4.0, 5.0], 1e-12);
            assert_near(&(s * t).unwrap().point([1.0, 1.0, 1.0]), &[4.0, 6.0, 8.0], 1e-12);
            let ts = (t * s).unwrap();
            assert_near(&(ts.inverse().unwrap() * ts).unwrap().point([3.0, -4.0, 5.0]), &[3.0, -4.0, 5.0], 1e-12);
            assert_eq!(Transform::from_rows(&t.rows()).unwrap(), t);
            let r = t.rows();
            let nested = [[r[0], r[1], r[2], r[3]], [r[4], r[5], r[6], r[7]], [r[8], r[9], r[10], r[11]], [r[12], r[13], r[14], r[15]]];
            assert_eq!(Transform::from_matrix(nested).unwrap(), t);
            assert_eq!(Transform::default(), Transform::identity());
            refusal(
                Transform::from_rows(&[1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0]),
                "Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)",
            );
            let fifteen: Vec<f64> = (0..15).map(f64::from).collect();
            refusal(Transform::from_rows(&fifteen), "Transform: a matrix is 16 numbers, got 15");
            let mut nan = Transform::identity().rows();
            nan[5] = f64::NAN;
            refusal(Transform::from_rows(&nan), "Transform: not finite");
            refusal(Transform::scale_xyz(&fxy(), 1.0, 1.0, 0.0).unwrap().inverse(), "transform_inverse: the map is singular");
        }

        #[test]
        fn the_transform_constructors_match_their_closed_forms() {
            if !kernel_present() {
                return;
            }
            let turn = Transform::rotation(&[[1.0, 0.0, 0.0], [0.0, 0.0, 1.0]], FRAC_PI_2).unwrap();
            assert_near(&turn.point([2.0, 0.0, 0.0]), &[1.0, 1.0, 0.0], 1e-12);
            assert_near(&Transform::mirror(&Frame::xy([0.0, 0.0, 5.0])).unwrap().point([1.0, 2.0, 3.0]), &[1.0, 2.0, 7.0], 1e-12);
            assert_near(&Transform::scale_xyz(&fxy(), 2.0, 3.0, 4.0).unwrap().point([1.0, 1.0, 1.0]), &[2.0, 3.0, 4.0], 1e-12);
            let about = Transform::scale([1.0, 2.0, 3.0], 2.0).unwrap();
            assert_near(&about.point([2.0, 2.0, 3.0]), &[3.0, 2.0, 3.0], 1e-12);
            assert_near(&about.point([1.0, 2.0, 3.0]), &[1.0, 2.0, 3.0], 1e-12);
            assert_near(&Transform::shear(&fxy(), [5.0, 0.0, 0.0], 0.5).unwrap().point([0.0, 0.0, 2.0]), &[1.0, 0.0, 2.0], 1e-12);
            assert_near(&Transform::planar_projection(&fxy()).unwrap().point([1.0, 2.0, 3.0]), &[1.0, 2.0, 0.0], 1e-12);
            assert_near(&Transform::project_along(&fxy(), [1.0, 0.0, 1.0]).unwrap().point([0.0, 0.0, 2.0]), &[-2.0, 0.0, 0.0], 1e-12);
            let b = Frame::xy([1.0, 2.0, 3.0]);
            assert_near(&Transform::plane_to_plane(&fxy(), &b).unwrap().point(ORIGIN), &[1.0, 2.0, 3.0], 1e-12);
            assert_near(&Transform::change_basis(&b, &fxy()).unwrap().point(ORIGIN), &[1.0, 2.0, 3.0], 1e-12);
            refusal(Transform::shear(&fxy(), [0.0, 0.0, 1.0], 0.5), "transform_shear: the shear direction must lie in the plane");
            // Through the unchecked raw frame: `Frame::of` would refuse it first, in this crate's words.
            let skew = Frame::raw_unchecked([0.0, 0.0, 0.0, 1.0, 1e-3, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
            refusal(Transform::mirror(&skew), "transform_mirror: the frame is not right-handed and orthonormal");
        }

        #[test]
        fn maps_are_told_and_split() {
            if !kernel_present() {
                return;
            }
            let turn = Transform::rotation(&[[1.0, 2.0, 3.0], [1.0, 1.0, 0.0]], 0.7).unwrap();
            assert!(turn.is_rigid(MAP_TOLERANCE).unwrap());
            assert!((turn.is_similarity(MAP_TOLERANCE).unwrap().unwrap() - 1.0).abs() < 1e-9);
            let big = (Transform::scale(ORIGIN, 2.5).unwrap() * turn).unwrap();
            assert!(!big.is_rigid(MAP_TOLERANCE).unwrap());
            assert!((big.is_similarity(MAP_TOLERANCE).unwrap().unwrap() - 2.5).abs() < 1e-9);
            let split = big.decompose_similarity(MAP_TOLERANCE).unwrap().unwrap();
            assert!((split.k - 2.5).abs() < 1e-9 && split.orthogonal.is_rigid(MAP_TOLERANCE).unwrap());
            let scaled = Transform::scale([1.0, 2.0, 3.0], 2.0).unwrap().decompose_similarity(MAP_TOLERANCE).unwrap().unwrap();
            assert_near(&scaled.translation, &[-1.0, -2.0, -3.0], 1e-12);
            assert!((scaled.k - 2.0).abs() < 1e-12);
            assert_eq!(scaled.orthogonal, Transform::identity());
            let rigid = turn.decompose_rigid(MAP_TOLERANCE).unwrap().unwrap();
            let r = turn.rows();
            assert_near(&rigid.translation, &[r[3], r[7], r[11]], 1e-12);
            assert!(rigid.orthogonal.is_rigid(MAP_TOLERANCE).unwrap());
            let stretch = Transform::scale_xyz(&fxy(), 1.0, 2.0, 3.0).unwrap();
            assert_eq!(stretch.is_similarity(MAP_TOLERANCE).unwrap(), None);
            assert!(stretch.decompose_rigid(MAP_TOLERANCE).unwrap().is_none());
            assert!(stretch.decompose_similarity(MAP_TOLERANCE).unwrap().is_none());
            let polar = (Transform::mirror(&fxy()).unwrap() * stretch).unwrap().decompose_affine().unwrap().unwrap();
            assert_near(&polar.stretch, &[3.0, 2.0, 1.0], 1e-9);
            // Only `rotation` carries the mirror; `axes` is a proper rotation -- which pins the order.
            assert!((det(&polar.rotation) + 1.0).abs() < 1e-9, "det(rotation) = {}", det(&polar.rotation));
            assert!((det(&polar.axes) - 1.0).abs() < 1e-9, "det(axes) = {}", det(&polar.axes));
            assert!(Transform::planar_projection(&fxy()).unwrap().decompose_affine().unwrap().is_none());
            refusal(turn.is_rigid(-1.0), "transform_is_rigid: the tolerance must be finite and not negative");
            refusal(turn.is_similarity(-1.0), "transform_is_similarity: the tolerance must be finite and not negative");
        }

        #[test]
        fn a_quaternion_turns_as_its_transform_does() {
            if !kernel_present() {
                return;
            }
            let q = Quaternion::from_axis_angle([0.0, 0.0, 2.0], FRAC_PI_2).unwrap();
            assert_near(&q.components(), &[FRAC_PI_4.cos(), 0.0, 0.0, FRAC_PI_4.sin()], 1e-12);
            assert!((q.angle() - FRAC_PI_2).abs() < 1e-12);
            assert_near(&q.axis().unwrap(), &[0.0, 0.0, 1.0], 1e-12);
            assert_near(&q.to_transform([1.0, 0.0, 0.0]).unwrap().point([2.0, 0.0, 0.0]), &[1.0, 1.0, 0.0], 1e-12);
            let [w, x, y, z] = q.components();
            let doubled = Quaternion::new(2.0 * w, 2.0 * x, 2.0 * y, 2.0 * z).unwrap();
            assert_near(&doubled.to_transform(ORIGIN).unwrap().point([1.0, 0.0, 0.0]), &[0.0, 1.0, 0.0], 1e-12);
            assert_near(&Quaternion::from_transform(&q.to_transform(ORIGIN).unwrap()).unwrap().components(), &q.components(), 1e-12);
            assert!((Quaternion::slerp(&Quaternion::identity(), &q, 0.25).unwrap().angle() - FRAC_PI_8).abs() < 1e-12);
            assert_near(&(q * q.conjugate()).unwrap().components(), &[1.0, 0.0, 0.0, 0.0], 1e-12);
            assert_eq!(Quaternion::new(0.0, 0.0, 0.0, 2.0).unwrap().normalized().unwrap(), Quaternion::new(0.0, 0.0, 0.0, 1.0).unwrap());
            refusal(Quaternion::new(0.0, 0.0, 0.0, 0.0).unwrap().to_transform(ORIGIN), "quaternion_to_transform: the quaternion is zero");
            refusal(Quaternion::from_transform(&Transform::mirror(&fxy()).unwrap()), "quaternion_from_transform: ");
            refusal(Quaternion::new(f64::INFINITY, 0.0, 0.0, 0.0), "Quaternion: not finite");
            // The product's sign pattern, against Python's literal.
            let about_x = Quaternion::from_axis_angle([1.0, 0.0, 0.0], FRAC_PI_2).unwrap();
            let about_y = Quaternion::from_axis_angle([0.0, 1.0, 0.0], FRAC_PI_2).unwrap();
            assert_near(&(about_x * about_y).unwrap().components(), &[0.5, 0.5, 0.5, 0.5], 1e-12);
            // Every term of every component non-zero, so any one sign flipped shows.
            let product = (Quaternion::new(1.0, 2.0, 3.0, 4.0).unwrap() * Quaternion::new(5.0, 6.0, 7.0, 8.0).unwrap()).unwrap();
            assert_eq!(product.components(), [-60.0, 12.0, 30.0, 24.0]);
        }

        #[test]
        fn a_quaternion_far_from_unit_length_normalises_like_the_abi() {
            let half = 0.5f64.sqrt();
            for k in [1e200, 1e-170] {
                let q = |w, x, y, z| Quaternion::new(w, x, y, z).unwrap();
                assert_eq!(q(k, 0.0, 0.0, 0.0).normalized().unwrap(), q(1.0, 0.0, 0.0, 0.0));
                assert_eq!(q(0.0, 0.0, 0.0, -k).normalized().unwrap(), q(0.0, 0.0, 0.0, -1.0));
                assert_near(&q(k, k, 0.0, 0.0).normalized().unwrap().components(), &[half, half, 0.0, 0.0], 1e-12);
                let length = q(k, k, 0.0, 0.0).length();
                assert!(((length - k * 2f64.sqrt()) / (k * 2f64.sqrt())).abs() <= 1e-15, "{k}: length {length}");
                assert!((q(k, k, 0.0, 0.0).angle() - FRAC_PI_2).abs() < 1e-12);
                assert_near(&q(0.0, k, k, 0.0).axis().unwrap(), &[half, half, 0.0], 1e-12);
            }
            refusal(Quaternion::new(0.0, 0.0, 0.0, 0.0).unwrap().normalized(), "Quaternion.normalized: the quaternion is zero");
        }

        #[test]
        fn a_solid_takes_any_affine_map() {
            if !kernel_present() {
                return;
            }
            let fxy = fxy();
            let block = Solid::cuboid(1.0, 2.0, 3.0).unwrap();
            assert_eq!(block.inexact_trims(), 0, "a solid no map made has lost nothing");
            let stretched = block.transform(&Transform::scale_xyz(&fxy, 2.0, 3.0, 0.5).unwrap()).unwrap();
            let (lo, hi) = stretched.bounds_at(0.05).unwrap();
            assert_near(&[hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]], &[2.0, 6.0, 1.5], 1e-9);
            assert_eq!(stretched.inexact_trims(), 0);
            let moved = block.transform(&Transform::from_rows(&Transform::translation([1.0, 0.0, 0.0]).unwrap().rows()).unwrap()).unwrap();
            assert_eq!(moved.inexact_trims(), 0);
            let sheared = Solid::cylinder(1.0, 2.0).unwrap().transform(&Transform::shear(&fxy, [1.0, 0.0, 0.0], 0.5).unwrap()).unwrap();
            let volume = sheared.mass(1e-7).unwrap().volume;
            assert!(((volume - 2.0 * PI) / (2.0 * PI)).abs() < 1e-6, "volume {volume}");
            let kinds: Vec<String> = (0..sheared.faces().unwrap()).map(|i| sheared.face_kind(i).unwrap()).collect();
            assert!(kinds.iter().any(|k| k == "nurbs"), "{kinds:?}");
            refusal(block.transform(&Transform::scale_xyz(&fxy, 1.0, 1.0, 0.0).unwrap()), "solid_transform: a singular map flattens the solid");
        }

        #[test]
        fn a_mapped_solid_keeps_its_colours_and_name() {
            if !kernel_present() {
                return;
            }
            let can = Solid::cylinder(1.0, 2.0).unwrap().coloured("#808080", None).unwrap().named("can").unwrap();
            let side = (0..can.faces().unwrap()).find(|&i| can.face_kind(i).unwrap() == "cylinder").unwrap();
            let can = can.coloured([0.2, 0.4, 1.0], Some(side)).unwrap();
            let shear = Transform::shear(&fxy(), [1.0, 0.0, 0.0], 0.5).unwrap();
            for out in [can.transform(&shear).unwrap(), can.convert_to_nurbs(NurbsLevel::All).unwrap()] {
                assert_eq!(out.faces().unwrap(), can.faces().unwrap());
                assert_eq!(out.face_colour(side).unwrap(), Some([0.2, 0.4, 1.0]));
                for i in (0..out.faces().unwrap()).filter(|&i| i != side) {
                    assert_eq!(out.face_colour(i).unwrap(), can.colour().unwrap(), "face {i}");
                }
                assert_eq!(out.name().as_deref(), Some("can"));
            }
        }

        #[test]
        fn a_solid_converts_to_nurbs_at_each_level() {
            if !kernel_present() {
                return;
            }
            let can = Solid::cylinder(1.0, 2.0).unwrap();
            let every = can.convert_to_nurbs(NurbsLevel::default()).unwrap();
            let kinds = |s: &Solid| -> Vec<String> { (0..s.faces().unwrap()).map(|i| s.face_kind(i).unwrap()).collect() };
            assert!(kinds(&every).iter().all(|k| k == "nurbs"), "{:?}", kinds(&every));
            assert_eq!(every.inexact_trims(), 0);
            let analytic = kinds(&can.convert_to_nurbs(NurbsLevel::Analytic).unwrap());
            assert!(analytic.iter().any(|k| k == "plane") && analytic.iter().any(|k| k == "nurbs"), "{analytic:?}");
            // The level is an enum here: there is no bad level to refuse.
        }

        #[test]
        fn a_profile_turns_scales_mirrors_and_maps() {
            if !kernel_present() {
                return;
            }
            let rect = Profile::rect(80.0, 40.0).unwrap();
            // (x span, y span, x centre, y centre)
            let measure = |p: &Profile| -> [f64; 4] {
                let points: Vec<[f32; 3]> = p.polylines(0.01).unwrap().into_iter().flatten().collect();
                let (mut lo, mut hi) = ([f64::INFINITY; 2], [f64::NEG_INFINITY; 2]);
                for q in &points {
                    for a in 0..2 {
                        lo[a] = lo[a].min(f64::from(q[a]));
                        hi[a] = hi[a].max(f64::from(q[a]));
                    }
                }
                [hi[0] - lo[0], hi[1] - lo[1], (hi[0] + lo[0]) / 2.0, (hi[1] + lo[1]) / 2.0]
            };
            let [_, _, rx, ry] = measure(&rect);
            assert_near(&measure(&rect.rotate([0.0, 0.0], FRAC_PI_2).unwrap())[..2], &[40.0, 80.0], 1e-3);
            assert_near(&measure(&rect.scale([0.0, 0.0], 0.5, 2.0).unwrap())[..2], &[40.0, 80.0], 1e-3);
            // Off the origin, so the argument order shows.
            assert_near(&measure(&rect.rotate([10.0, 20.0], FRAC_PI_2).unwrap())[2..], &[10.0 - (ry - 20.0), 20.0 + (rx - 10.0)], 1e-3);
            assert_near(&measure(&rect.scale([10.0, 0.0], 0.5, 2.0).unwrap())[2..], &[10.0 + 0.5 * (rx - 10.0), 2.0 * ry], 1e-3);
            assert_near(&measure(&rect.mirror([100.0, 0.0], [0.0, 1.0]).unwrap())[2..3], &[200.0], 1e-3);
            assert_near(&measure(&rect.transform2d([1.0, 0.5, 0.0, 0.0, 1.0, 0.0]).unwrap())[..1], &[100.0], 1e-3);
            refusal(rect.transform2d([1.0, 2.0, 0.0, 2.0, 4.0, 0.0]), "profile_transform2d: the 2D map is singular");
        }
    }

    // ---- value geometry (plan B3): Interval, the frame verbs, the nine values -------------
    //
    // Python's TestInterval ... TestCuboidValue, the same figures and tolerances. The Rhino
    // records are the file B1's crates/cadaclysm/tests/rhino_values.rs reads.

    mod values {
        use super::*;
        use std::collections::hash_map::DefaultHasher;
        use std::collections::{HashMap, HashSet};
        use std::f64::consts::{FRAC_PI_2, PI};

        const EXACT: f64 = 1e-12;
        const NURBS_FOOT: f64 = 1e-7;
        const XY: [f64; 12] = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        /// Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
        const YZX: [f64; 12] = [1.0, 2.0, 3.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0];

        type Records = HashMap<(String, String), Vec<String>>;

        /// The Rhino records, from beside this crate's manifest -- never the working
        /// directory -- and a missing file fails, never skips.
        fn vectors() -> Records {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../cadaclysm/tests/fixtures/rhino/value_vectors.txt");
            let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("the Rhino value vectors {}: {e}", path.display()));
            let mut records = Records::new();
            for line in text.lines() {
                let line = line.trim();
                assert!(!line.contains("ERROR"), "{line}");
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let mut words = line.split_whitespace().map(str::to_string);
                let (case, what) = (words.next().unwrap(), words.next().unwrap());
                let key = (case, what);
                assert!(!records.contains_key(&key), "{key:?} twice");
                records.insert(key, words.collect());
            }
            records
        }

        fn nums(r: &Records, case: &str, what: &str) -> Vec<f64> {
            r.get(&(case.to_string(), what.to_string()))
                .unwrap_or_else(|| panic!("no record {case} {what}"))
                .iter()
                .map(|w| w.parse::<f64>().unwrap_or_else(|e| panic!("{case} {what}: {w}: {e}")))
                .collect()
        }

        fn close(got: &[f64], want: &[f64], tol: f64, label: &str) {
            assert_eq!(got.len(), want.len(), "{label}: {got:?} vs {want:?}");
            for (g, w) in got.iter().zip(want) {
                assert!((g - w).abs() <= tol, "{label}: {got:?} vs {want:?}");
            }
        }

        fn p3(v: &[f64]) -> [f64; 3] {
            [v[0], v[1], v[2]]
        }

        fn queries(r: &Records, shape: &str) -> Vec<(String, [f64; 3])> {
            (0..12).map(|i| format!("{shape}_{i:02}")).map(|case| { let q = p3(&nums(r, &case, "query")); (case, q) }).collect()
        }

        fn dist(a: [f64; 3], b: [f64; 3]) -> f64 {
            ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
        }

        /// A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never
        /// beaten by Rhino's, the point to 1e-7 -- as B1's `nurbs_foot`.
        fn nurbs_foot(label: &str, q: [f64; 3], ours: [f64; 3], rhino: &[f64]) {
            let (d, dr) = (dist(q, ours), dist(q, p3(rhino)));
            assert!(d <= dr + EXACT && (d - dr).abs() <= EXACT, "{label}: {d} vs {dr}");
            close(&ours, rhino, NURBS_FOOT, label);
        }

        fn refused<T: fmt::Debug>(result: Result<T>) -> String {
            result.expect_err("this should have been refused").message().to_string()
        }

        fn iv(t0: f64, t1: f64) -> Interval {
            Interval::new(t0, t1).unwrap()
        }

        fn hash_of<T: Hash>(v: &T) -> u64 {
            let mut h = DefaultHasher::new();
            v.hash(&mut h);
            h.finish()
        }

        fn xy() -> Frame {
            Frame::of(XY).unwrap()
        }

        fn yzx() -> Frame {
            Frame::of(YZX).unwrap()
        }

        fn with(frame: [f64; 12], rest: &[f64]) -> Vec<f64> {
            frame.iter().chain(rest).copied().collect()
        }

        // -- Interval (TestInterval)

        #[test]
        fn an_interval_measures_keep_the_orientation() {
            let (up, down) = (iv(2.0, 6.0), iv(6.0, 2.0));
            assert_eq!((up.length(), down.length()), (4.0, -4.0));
            assert!(up.mid() == 4.0 && down.mid() == 4.0);
            assert_eq!((up.min(), up.max()), (2.0, 6.0));
            assert_eq!((down.min(), down.max()), (2.0, 6.0));
            assert!(up.is_increasing() && !down.is_increasing() && !iv(3.0, 3.0).is_increasing());
            assert!(iv(3.0, 3.0).is_singleton() && !up.is_singleton());
            assert!(up.swapped() == down && down.swapped() == up);
            assert_eq!(down.values(), [6.0, 2.0]);
            assert_eq!((down.t0(), down.t1()), (6.0, 2.0));
        }

        #[test]
        fn an_intervals_set_operations_answer_increasing_and_touching_is_a_singleton() {
            let (up, down) = (iv(2.0, 6.0), iv(6.0, 2.0));
            assert_eq!(up.grown(9.0).unwrap(), iv(2.0, 9.0));
            assert_eq!(down.grown(-1.0).unwrap(), iv(-1.0, 6.0));
            assert_eq!(down.grown(3.0).unwrap(), up);
            assert_eq!(up.union(iv(8.0, 7.0)), iv(2.0, 8.0));
            assert_eq!(down.union(iv(1.0, 3.0)), iv(1.0, 6.0));
            assert_eq!(down.intersect(iv(9.0, 4.0)), Some(iv(4.0, 6.0)));
            assert_eq!(up.intersect(iv(3.0, 5.0)), Some(iv(3.0, 5.0)));
            assert_eq!(up.intersect(iv(7.0, 9.0)), None);
            assert_eq!(down.intersect(iv(1.0, 1.5)), None);
            assert_eq!(iv(0.0, 1.0).intersect(iv(1.0, 2.0)), Some(iv(1.0, 1.0)));
            assert_eq!(iv(2.0, 1.0).intersect(iv(0.0, 1.0)), Some(iv(1.0, 1.0)));
            for x in [up, down] {
                assert!(x.contains(2.0) && x.contains(6.0) && x.contains(4.5));
                assert!(!x.contains(1.999) && !x.contains(6.001));
            }
        }

        #[test]
        fn an_intervals_parameters_round_trip() {
            assert_eq!(iv(2.0, 6.0).parameter_at(0.25), 3.0);
            assert_eq!(iv(6.0, 2.0).parameter_at(0.25), 5.0);
            for x in [iv(2.0, 6.0), iv(6.0, 2.0), iv(-1.5, 0.7)] {
                for s in [-0.5, 0.0, 0.3, 1.0, 2.0] {
                    assert!((x.normalized_parameter_at(x.parameter_at(s)).unwrap() - s).abs() <= 1e-15, "{x:?} {s}");
                }
            }
            assert_eq!(iv(3.0, 3.0).normalized_parameter_at(3.0), None);
        }

        #[test]
        fn an_interval_is_a_hashable_value_and_refuses_what_is_not_finite() {
            let a = iv(1.0, 2.0);
            assert_eq!(a, iv(1.0, 2.0));
            assert_eq!(hash_of(&a), hash_of(&iv(1.0, 2.0)));
            assert_eq!(HashSet::from([a, iv(1.0, 2.0)]).len(), 1);
            assert_eq!(hash_of(&iv(-0.0, 1.0)), hash_of(&iv(0.0, 1.0)));
            assert_eq!((1.0, 2.0).interval().unwrap(), a);
            assert_eq!([1.0, 2.0].interval().unwrap(), a);
            assert_eq!(Interval::of(a).unwrap(), a);
            assert_eq!(Interval::of((2.0, 1.0)).unwrap(), a.swapped());
            assert_eq!(refused(Interval::new(f64::NAN, 1.0)), "Interval: not finite");
            assert_eq!(refused((1.0, f64::INFINITY).interval()), "Interval: not finite");
            assert_eq!(refused(a.grown(f64::INFINITY)), "Interval: not finite");
        }

        #[test]
        fn an_interval_matches_rhino() {
            let r = vectors();
            for name in ["apart", "dec_dec", "inc_dec", "inc_inc", "touch"] {
                let case = format!("interval_{name}");
                let args = nums(&r, &case, "args");
                let (a, b) = (iv(args[0], args[1]), iv(args[2], args[3]));
                assert_eq!(a.union(b).values().to_vec(), nums(&r, &case, "union"), "{case}");
                let got = a.intersect(b);
                if r[&(case.clone(), "intersection".to_string())] == ["none"] {
                    assert_eq!(got, None, "{case}");
                } else {
                    assert_eq!(got.expect(&case).values().to_vec(), nums(&r, &case, "intersection"), "{case}");
                }
            }
            for name in ["inc_inside", "inc_out", "dec_low", "dec_inside"] {
                let case = format!("grow_{name}");
                let args = nums(&r, &case, "args");
                assert_eq!(iv(args[0], args[1]).grown(args[2]).unwrap().values().to_vec(), nums(&r, &case, "grown"), "{case}");
            }
            for name in ["inc", "dec"] {
                for k in 0..4 {
                    let case = format!("param_{name}_{k}");
                    let args = nums(&r, &case, "args");
                    let (x, t) = (iv(args[0], args[1]), args[2]);
                    close(&[x.parameter_at(t)], &nums(&r, &case, "parameter_at"), EXACT, &case);
                    close(&[x.normalized_parameter_at(2.5 + t).unwrap()], &nums(&r, &case, "normalized_at"), EXACT, &case);
                }
            }
        }

        // -- the frame verbs (TestFrameVerbs)

        #[test]
        fn the_plane_verbs_match_rhino() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let frame: [f64; 12] = nums(&r, "plane", "frame").try_into().unwrap();
            let p = Frame::of(frame).unwrap();
            close(&p.flipped().raw(), &nums(&r, "plane", "flip"), EXACT, "flip");
            close(&p.rotated(0.6, [1.0, -1.0, 0.5]).unwrap().raw(), &nums(&r, "plane", "rotate"), EXACT, "rotate");
            for (case, q) in queries(&r, "plane") {
                close(&p.to_local(q), &nums(&r, &case, "remap"), EXACT, &case);
                close(&p.closest_point(q), &nums(&r, &case, "closest"), EXACT, &case);
                close(&[p.distance_to(q)], &nums(&r, &case, "distance"), EXACT, &case);
            }
        }

        #[test]
        fn a_frame_fit_matches_rhino_and_refuses_in_the_librarys_words() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let pts: Vec<[f64; 3]> = nums(&r, "fit", "points").chunks_exact(3).map(p3).collect();
            let (got, deviation) = Frame::fit(&pts).unwrap();
            let want = Frame::of(nums(&r, "fit", "frame").try_into().unwrap()).unwrap();
            let sign = if dot(got.z(), want.z()) < 0.0 { -1.0 } else { 1.0 };
            close(&got.z().map(|c| sign * c), &want.z(), EXACT, "normal");
            close(&[want.distance_to(got.origin()), got.distance_to(want.origin())], &[0.0, 0.0], EXACT, "origins");
            close(&[deviation], &nums(&r, "fit", "deviation"), EXACT, "deviation");
            assert_eq!(refused(Frame::fit(&pts[..2])), "frame_fit: needs three points");
            assert_eq!(refused(Frame::fit(&[[0.0; 3], [1.0; 3], [2.0; 3]])), "frame_fit: the points lie on one line");
        }

        // -- curves (TestCurveValues)

        #[test]
        fn a_bad_curve_is_refused_by_value_check() {
            if !kernel_present() {
                return;
            }
            let xy = xy();
            assert_eq!(refused(Circle::new(&xy, 0.0)), "value_check: the radius must be positive");
            assert_eq!(refused(Line::new([1.0; 3], [1.0; 3])), "value_check: the line has no length");
            assert_eq!(refused(Arc::new(&xy, 1.0, (0.0, 7.0))), "value_check: the angle must increase by at most a full turn");
            assert_eq!(refused(Arc::new(&xy, 1.0, iv(1.0, 0.0))), "value_check: the angle must increase by at most a full turn");
            assert_eq!(refused(Ellipse::new(&xy, 3.0, -1.0)), "value_check: the second radius must be positive");
            let skew = [0.0, 0.0, 0.0, 1.0, 1e-3, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
            assert_eq!(refused(Circle::from_values(&with(skew, &[1.0]))), "value_check: the frame is not right-handed and orthonormal");
            // The count, in the library's own sentence, before value_check is called.
            assert_eq!(refused(Circle::from_values(&XY)), "value_check: a circle is 13 numbers, got 12");
            // 1e-7 off square is squared up, not refused.
            let near = Circle::from_values(&with([0.0, 0.0, 0.0, 1.0, 1e-7, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0], &[1.0])).unwrap();
            assert!(dot(near.frame().x(), near.frame().y()).abs() < 1e-15 && near.frame().x()[1] != 0.0, "{near:?}");
        }

        #[test]
        fn each_curve_call_answers_b1s_figures() {
            if !kernel_present() {
                return;
            }
            let unit = Circle::new(&xy(), 1.0).unwrap();
            close(&unit.point_at(FRAC_PI_2).unwrap(), &[0.0, 1.0, 0.0], 1e-15, "point_at");
            close(&unit.tangent_at(0.0).unwrap(), &[0.0, 1.0, 0.0], 1e-15, "tangent_at");
            let line = Line::new([0.0; 3], [1.0, 2.0, 3.0]).unwrap();
            assert_eq!(line.point_at(0.5).unwrap(), [0.5, 1.0, 1.5]);
            assert_eq!(line.length().unwrap(), 14f64.sqrt());
            assert_eq!((line.start(), line.end()), ([0.0; 3], [1.0, 2.0, 3.0]));
            close(&line.tangent_at(0.0).unwrap(), &[1.0, 2.0, 3.0].map(|c| c / 14f64.sqrt()), 1e-15, "line tangent");
            let quarter = Arc::new(&xy(), 2.0, (0.0, FRAC_PI_2)).unwrap();
            assert_eq!(quarter.length().unwrap(), PI);
            assert_eq!(quarter.angle(), iv(0.0, FRAC_PI_2));
            close(&quarter.start().unwrap(), &[2.0, 0.0, 0.0], 1e-15, "start");
            close(&quarter.end().unwrap(), &[0.0, 2.0, 0.0], 1e-15, "end");
            close(&quarter.mid().unwrap(), &[2f64.sqrt(), 2f64.sqrt(), 0.0], 1e-15, "mid");
            // On the axis the foot is a pick: t = 0, not unique.
            assert_eq!(unit.closest_point([2.0, 0.0, 5.0]).unwrap(), CurveFoot { t: 0.0, point: [1.0, 0.0, 0.0], unique: true });
            assert_eq!(unit.closest_point([0.0, 0.0, 5.0]).unwrap(), CurveFoot { t: 0.0, point: [1.0, 0.0, 0.0], unique: false });
            assert!((unit.distance_to([2.0, 0.0, 5.0]).unwrap() - 26f64.sqrt()).abs() < 1e-12);
            assert_eq!(Line::new([1.0, 5.0, 0.0], [0.0, 2.0, 3.0]).unwrap().bounds().unwrap(), ([0.0, 2.0, 0.0], [1.0, 5.0, 3.0]));
            let perimeter = Ellipse::new(&xy(), 3.0, 1.0).unwrap().length().unwrap();
            assert!(((perimeter - 13.364893220555258) / 13.364893220555258).abs() <= 1e-12, "{perimeter}");
        }

        #[test]
        fn curve_constructors_and_transforms() {
            if !kernel_present() {
                return;
            }
            let (a, b, c) = ([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [-1.0, 0.0, 0.0]);
            close(&Circle::through(a, b, c).unwrap().values(), &with(XY, &[1.0]), 1e-15, "circle through");
            close(&Arc::through(a, b, c).unwrap().values(), &with(XY, &[1.0, 0.0, PI]), 1e-15, "arc through");
            close(&Arc::from_start_tangent_end(a, [0.0, 1.0, 0.0], c).unwrap().values(), &with(XY, &[1.0, 0.0, PI]), 1e-15, "arc from tangent");
            assert_eq!(refused(Circle::through(a, a, c)), "circle_through: the points are coincident or collinear");
            assert_eq!(
                refused(Arc::from_start_tangent_end(a, [0.0; 3], c)),
                "arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line"
            );
            assert_eq!(Ellipse::from_circle(&Circle::new(&xy(), 2.0).unwrap()).unwrap(), Ellipse::new(&xy(), 2.0, 2.0).unwrap());
            let unit = Circle::new(&xy(), 1.0).unwrap();
            assert_eq!(unit.transform(&Transform::scale([0.0; 3], 2.0).unwrap()).unwrap(), Circle::new(&xy(), 2.0).unwrap());
            let stretch = Transform::scale_xyz(&Frame::xy([0.0; 3]), 1.0, 3.0, 1.0).unwrap();
            assert_eq!(refused(unit.transform(&stretch)), "value_transform: a circle takes only a similarity (use ellipse_from_circle)");
            let e = Ellipse::from_circle(&unit).unwrap().transform(&stretch).unwrap();
            close(&[e.r1(), e.r2()], &[3.0, 1.0], 1e-15, "stretched");
            let moved = Line::new([0.0; 3], [1.0, 0.0, 0.0]).unwrap().transform(&Transform::translation([0.0, 0.0, 2.0]).unwrap()).unwrap();
            assert_eq!(moved, Line::new([0.0, 0.0, 2.0], [1.0, 0.0, 2.0]).unwrap());
        }

        #[test]
        fn values_compare_and_hash_by_kind_and_array() {
            if !kernel_present() {
                return;
            }
            let c = Circle::new(&yzx(), 2.0).unwrap();
            assert_eq!(c.values().to_vec(), with(YZX, &[2.0]));
            assert_eq!(c.radius(), 2.0);
            assert_eq!(c.frame(), yzx());
            assert_eq!(c, Circle::from_values(&with(YZX, &[2.0])).unwrap());
            assert_eq!(hash_of(&c), hash_of(&Circle::new(&yzx(), 2.0).unwrap()));
            // A sphere of the same numbers: the arrays coincide, only the kind tells them apart
            // (`c == sphere` does not compile, so the hash is where it shows).
            let sphere = Sphere::new(&yzx(), 2.0).unwrap();
            assert_eq!(c.values(), sphere.values());
            assert_ne!(hash_of(&c), hash_of(&sphere));
            assert_eq!(HashSet::from([CurveValue::Circle(c), CurveValue::from(Circle::new(&yzx(), 2.0).unwrap())]).len(), 1);
            assert!(format!("{c:?}").starts_with("Circle {"), "{c:?}");
        }

        #[test]
        fn lines_circles_and_arcs_match_rhino() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let ends = nums(&r, "line", "ends");
            let line = Line::new(p3(&ends[0..3]), p3(&ends[3..6])).unwrap();
            close(&[line.length().unwrap()], &nums(&r, "line", "length"), EXACT, "line length");
            close(&line.tangent_at(0.5).unwrap(), &nums(&r, "line", "tangent"), EXACT, "line tangent");
            for k in 0..5 {
                let n = nums(&r, &format!("line_at_{k}"), "point");
                close(&line.point_at(n[0]).unwrap(), &n[1..], EXACT, &format!("line_at_{k}"));
            }
            for (case, q) in queries(&r, "line") {
                close(&line.closest_point(q).unwrap().point, &nums(&r, &case, "closest"), EXACT, &case);
            }

            let frame = |shape: &str| Frame::of(nums(&r, shape, "frame").try_into().unwrap()).unwrap();
            let circle = Circle::new(&frame("circle"), nums(&r, "circle", "radius")[0]).unwrap();
            close(&[circle.length().unwrap()], &nums(&r, "circle", "length"), EXACT, "circle length");
            for k in 0..5 {
                let (case, n) = (format!("circle_at_{k}"), nums(&r, &format!("circle_at_{k}"), "point"));
                close(&circle.point_at(n[0]).unwrap(), &n[1..4], EXACT, &case);
                close(&circle.tangent_at(n[0]).unwrap(), &n[4..7], EXACT, &format!("{case} tangent"));
            }
            for (case, q) in queries(&r, "circle") {
                let (want, foot) = (nums(&r, &case, "closest"), circle.closest_point(q).unwrap());
                assert!(foot.unique, "{case}");
                close(&[foot.t], &[want[0].rem_euclid(2.0 * PI)], EXACT, &case);
                close(&foot.point, &want[1..], EXACT, &case);
            }

            let arc = Arc::new(&frame("arc"), nums(&r, "arc", "radius")[0], <[f64; 2]>::try_from(nums(&r, "arc", "angle")).unwrap()).unwrap();
            close(&[arc.length().unwrap()], &nums(&r, "arc", "length"), EXACT, "arc length");
            for k in 0..4 {
                let (case, n) = (format!("arc_at_{k}"), nums(&r, &format!("arc_at_{k}"), "point"));
                close(&arc.point_at(n[0]).unwrap(), &n[1..4], EXACT, &case);
                close(&arc.tangent_at(n[0]).unwrap(), &n[4..7], EXACT, &format!("{case} tangent"));
            }
            for (case, q) in queries(&r, "arc") {
                let (want, foot) = (nums(&r, &case, "closest"), arc.closest_point(q).unwrap());
                close(&[foot.t], &want[..1], EXACT, &case);
                close(&foot.point, &want[1..], EXACT, &case);
            }
        }

        #[test]
        fn an_edges_curve_is_its_value() {
            if !kernel_present() {
                return;
            }
            let value = |e: &Edge| e.curve.as_ref().expect("an exact curve").value().unwrap();
            let can = Solid::cylinder(5.0, 3.0).unwrap();
            let rims: Vec<Edge> = can.edges().unwrap().into_iter().filter(|e| e.kind == "circle").collect();
            assert!(!rims.is_empty());
            for rim in &rims {
                let Some(CurveValue::Circle(v)) = value(rim) else { panic!("{:?}", value(rim)) };
                assert!((v.radius() - 5.0).abs() < 1e-9 && [0.0, 3.0].iter().any(|z| (v.frame().origin()[2] - z).abs() < 1e-9), "{v:?}");
            }
            let round9 = |p: [f64; 3]| p.map(|c| ((c * 1e9).round() / 1e9 + 0.0).to_bits());
            for e in Solid::cuboid(2.0, 4.0, 6.0).unwrap().edges().unwrap() {
                let Some(CurveValue::Line(v)) = value(&e) else { panic!("{:?}", value(&e)) };
                let ends: HashSet<_> = e.segments.iter().flatten().map(|p| round9(*p)).collect();
                assert!(ends.contains(&round9(v.start())) && ends.contains(&round9(v.end())), "{v:?} {:?}", e.segments);
            }
            let cube = Solid::cuboid(10.0, 10.0, 10.0).unwrap();
            let upright: Vec<u32> = cube.edges().unwrap().iter().filter(|e| e.direction().is_some_and(|d| (d[2].abs() - 1.0).abs() < 1e-9)).map(|e| e.index).collect();
            let rounded = cube.fillet(&upright[..1], 2.0, FILLET_TOLERANCE).unwrap();
            let arcs: Vec<Edge> = rounded.edges().unwrap().into_iter().filter(|e| e.kind == "circle").collect();
            assert_eq!(arcs.len(), 2);
            for e in &arcs {
                let Some(CurveValue::Arc(v)) = value(e) else { panic!("{:?}", value(e)) };
                assert!((v.radius() - 2.0).abs() < 1e-9 && (v.angle().length() - FRAC_PI_2).abs() < 1e-9, "{v:?}");
                let vertices = [e.segments[0][0], e.segments[e.segments.len() - 1][1]];
                assert!(vertices.iter().any(|p| dist(v.start().unwrap(), *p) < 1e-9), "{v:?}");
                assert!(vertices.iter().any(|p| dist(v.end().unwrap(), *p) < 1e-9), "{v:?}");
            }
            let outline = Profile::spline(&[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]], 3, None, true).unwrap();
            let spline = Solid::extrude(&outline, &Frame::xy([0.0; 3]), 2.0).unwrap();
            let nurbs: Vec<Edge> = spline.edges().unwrap().into_iter().filter(|e| e.kind == "nurbs").collect();
            assert!(!nurbs.is_empty());
            assert!(nurbs.iter().all(|e| value(e).is_none()));
        }

        // -- surfaces (TestSurfaceValues)

        #[test]
        fn a_bad_surface_is_refused_by_value_check() {
            if !kernel_present() {
                return;
            }
            let xy = xy();
            assert_eq!(refused(Cylinder::new(&xy, 1.0, (2.0, 1.0))), "value_check: the height must increase");
            assert_eq!(refused(Torus::new(&xy, 1.0, 1.0)), "value_check: the minor radius must be less than the major");
            assert_eq!(refused(Cone::new(&xy, 1.0, 0.0)), "value_check: the height must be positive");
            assert_eq!(refused(Sphere::new(&xy, f64::NAN)), "value_check: not finite");
        }

        #[test]
        fn each_surface_call_answers_b1s_figures() {
            if !kernel_present() {
                return;
            }
            let sphere = Sphere::new(&xy(), 2.0).unwrap();
            close(&sphere.point_at(0.0, FRAC_PI_2).unwrap(), &[0.0, 0.0, 2.0], 1e-15, "point_at");
            let cyl = Cylinder::new(&xy(), 1.0, (-1.0, 2.0)).unwrap();
            assert_eq!(cyl.height(), iv(-1.0, 2.0));
            close(&cyl.normal_at(FRAC_PI_2, 0.0).unwrap(), &[0.0, 1.0, 0.0], 1e-15, "normal_at");
            close(&Torus::new(&xy(), 3.0, 1.0).unwrap().point_at(0.0, 0.0).unwrap(), &[4.0, 0.0, 0.0], 1e-15, "torus point");
            let foot = sphere.closest_point([0.0, 0.0, 5.0]).unwrap();
            assert!(foot.unique);
            close(&[foot.u, foot.v, foot.point[0], foot.point[1], foot.point[2]], &[0.0, FRAC_PI_2, 0.0, 0.0, 2.0], 1e-15, "foot");
            assert!(!sphere.closest_point([0.0; 3]).unwrap().unique, "the centre is a pick");
            assert!((sphere.distance_to([0.0, 0.0, 5.0]).unwrap() - 3.0).abs() < 1e-12);
            assert_eq!(cyl.domain().unwrap(), (iv(0.0, 2.0 * PI), iv(-1.0, 2.0)));
            assert_eq!(Cone::new(&xy(), 1.0, 2.0).unwrap().domain().unwrap(), (iv(0.0, 2.0 * PI), iv(0.0, 2.0)));
            assert!((sphere.volume().unwrap() - 32.0 * PI / 3.0).abs() < 1e-13 && (sphere.area().unwrap() - 16.0 * PI).abs() < 1e-13);
            assert!(Torus::new(&xy(), 3.0, 1.0).unwrap().contains([3.0, 0.0, 0.5], CONTAINS_TOLERANCE).unwrap());
            assert!(!sphere.contains([0.0, 0.0, 2.5], CONTAINS_TOLERANCE).unwrap());
            assert!(sphere.contains([0.0, 0.0, 2.5], 0.5).unwrap());
            assert_eq!(refused(sphere.contains([0.0; 3], -1.0)), "solid_value_contains: the tolerance must be finite and not negative");
            assert_eq!(sphere.bounds().unwrap(), ([-2.0; 3], [2.0; 3]));
            let stretch = Transform::scale_xyz(&Frame::xy([0.0; 3]), 1.0, 3.0, 1.0).unwrap();
            assert_eq!(refused(sphere.transform(&stretch)), "value_transform: a sphere takes only a similarity");
            assert_eq!(sphere.transform(&Transform::translation([1.0, 0.0, 0.0]).unwrap()).unwrap(), Sphere::new(&Frame::xy([1.0, 0.0, 0.0]), 2.0).unwrap());
            assert_eq!(cyl.to_nurbs_sheet().unwrap().faces().unwrap(), 1);
        }

        #[test]
        fn each_shape_becomes_a_solid_of_its_volume() {
            if !kernel_present() {
                return;
            }
            let (sphere, cyl) = (Sphere::new(&xy(), 2.0).unwrap(), Cylinder::new(&xy(), 1.0, (-1.0, 2.0)).unwrap());
            let (cone, torus) = (Cone::new(&xy(), 1.0, 2.0).unwrap(), Torus::new(&xy(), 3.0, 1.0).unwrap());
            let cuboid = Cuboid::new(&yzx(), (0.0, 1.0), (0.0, 2.0), (0.0, 3.0)).unwrap();
            let shapes: [(&str, Result<Solid>, f64, f64); 5] = [
                ("sphere", sphere.to_solid(), sphere.volume().unwrap(), 32.0 * PI / 3.0),
                ("cylinder", cyl.to_solid(), cyl.volume().unwrap(), 3.0 * PI),
                ("cone", cone.to_solid(), cone.volume().unwrap(), 2.0 * PI / 3.0),
                ("torus", torus.to_solid(), torus.volume().unwrap(), 6.0 * PI * PI),
                ("cuboid", cuboid.to_solid(), cuboid.volume().unwrap(), 6.0),
            ];
            for (name, solid, own, volume) in shapes {
                let measured = solid.unwrap().mass(1e-9).unwrap().volume;
                assert!(((measured - volume) / volume).abs() <= 1e-6, "{name}: {measured} vs {volume}");
                assert!(((own - volume) / volume).abs() <= 1e-12, "{name}: {own} vs {volume}");
            }
        }

        #[test]
        fn spheres_tori_cylinders_and_cones_match_rhino() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let frame = |shape: &str| Frame::of(nums(&r, shape, "frame").try_into().unwrap()).unwrap();
            let sphere = Sphere::new(&frame("sphere"), nums(&r, "sphere", "radius")[0]).unwrap();
            for (case, q) in queries(&r, "sphere") {
                let (want, foot) = (nums(&r, &case, "closest"), sphere.closest_point(q).unwrap());
                close(&[foot.u, foot.v], &[want[0].rem_euclid(2.0 * PI), want[1]], EXACT, &case);
                close(&foot.point, &want[2..], EXACT, &case);
            }
            let radii = nums(&r, "torus", "radii");
            let torus = Torus::new(&frame("torus"), radii[0], radii[1]).unwrap();
            for (case, q) in queries(&r, "torus") {
                let foot = torus.closest_point(q).unwrap();
                assert!(foot.unique, "{case}");
                nurbs_foot(&case, q, foot.point, &nums(&r, &case, "closest"));
            }
            let height = nums(&r, "cylinder", "height");
            let cyl = Cylinder::new(&frame("cylinder"), nums(&r, "cylinder", "radius")[0], (height[0], height[1])).unwrap();
            for (case, q) in queries(&r, "cylinder") {
                nurbs_foot(&case, q, cyl.closest_point(q).unwrap().point, &nums(&r, &case, "closest"));
            }
            let size = nums(&r, "cone", "size");
            let cone = Cone::new(&frame("cone"), size[0], size[1]).unwrap();
            for (case, q) in queries(&r, "cone") {
                nurbs_foot(&case, q, cone.closest_point(q).unwrap().point, &nums(&r, &case, "closest"));
            }
        }

        // -- the cuboid (TestCuboidValue)

        #[test]
        fn a_cuboids_construction_bounds_and_around() {
            if !kernel_present() {
                return;
            }
            let b = Cuboid::new(&yzx(), (0.0, 1.0), [0.0, 2.0], iv(0.0, 3.0)).unwrap();
            assert_eq!((b.x(), b.y(), b.z()), (iv(0.0, 1.0), iv(0.0, 2.0), iv(0.0, 3.0)));
            // x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
            assert_eq!(b.bounds().unwrap(), ([1.0, 2.0, 3.0], [4.0, 3.0, 5.0]));
            assert_eq!(Cuboid::from_bounds([0.0; 3], [1.0, 2.0, 3.0]).unwrap(), Cuboid::new(&xy(), (0.0, 1.0), (0.0, 2.0), (0.0, 3.0)).unwrap());
            assert_eq!(refused(Cuboid::from_bounds([0.0; 3], [1.0, 0.0, 3.0])), "cuboid_from_bounds: the bounds must increase along every axis");
            assert_eq!(refused(Cuboid::new(&xy(), (0.0, 1.0), (2.0, 2.0), (0.0, 1.0))), "value_check: the y range must increase");
            let pts = [[0.0, 0.0, 0.0], [1.0, 2.0, 3.0], [0.5, -1.0, 0.25]];
            assert_eq!(Cuboid::around(&Frame::xy([0.0; 3]), &pts).unwrap(), Cuboid::new(&xy(), (0.0, 1.0), (-1.0, 2.0), (0.0, 3.0)).unwrap());
            assert_eq!(refused(Cuboid::around(&xy(), &[[0.0; 3], [1.0, 1.0, 0.0]])), "cuboid_around: the points are flat along an axis of the frame");
            assert_eq!(refused(Cuboid::around(&xy(), &[])), "cuboid_around: no points");
        }

        #[test]
        fn each_cuboid_call_answers_b1s_figures() {
            if !kernel_present() {
                return;
            }
            let b = Cuboid::new(&xy(), (0.0, 1.0), (0.0, 2.0), (0.0, 3.0)).unwrap();
            assert_eq!((b.area().unwrap(), b.volume().unwrap()), (22.0, 6.0));
            assert!(b.contains([0.5; 3], CONTAINS_TOLERANCE).unwrap());
            assert!(!b.contains([1.5, 0.5, 0.5], 0.4).unwrap() && b.contains([1.5, 0.5, 0.5], 0.5).unwrap());
            let tilted = Cuboid::new(&yzx(), (0.0, 1.0), (0.0, 2.0), (0.0, 3.0)).unwrap();
            assert_eq!(tilted.closest_point([9.0; 3]).unwrap(), [4.0, 3.0, 5.0]);
            close(&tilted.point_at(0.5, 0.5, 0.5).unwrap(), &[2.5, 2.5, 4.0], 1e-15, "point_at");
            let corners = b.corners().unwrap();
            assert_eq!((corners[0], corners[2], corners[6]), ([0.0; 3], [1.0, 2.0, 0.0], [1.0, 2.0, 3.0]));
            let moved = b.transform(&Transform::translation([0.0, 0.0, 1.0]).unwrap()).unwrap();
            assert_eq!(moved.bounds().unwrap(), ([0.0, 0.0, 1.0], [1.0, 2.0, 4.0]));
        }

        #[test]
        fn boxes_match_rhino() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let ranges = nums(&r, "box", "ranges");
            let frame = Frame::of(nums(&r, "box", "frame").try_into().unwrap()).unwrap();
            let b = Cuboid::new(&frame, (ranges[0], ranges[1]), (ranges[2], ranges[3]), (ranges[4], ranges[5])).unwrap();
            let corners = nums(&r, "box", "corners");
            for (k, c) in b.corners().unwrap().iter().enumerate() {
                close(c, &corners[3 * k..3 * k + 3], EXACT, &format!("corner {k}"));
            }
            for k in 0..4 {
                let n = nums(&r, &format!("box_at_{k}"), "point");
                close(&b.point_at(n[0], n[1], n[2]).unwrap(), &n[3..6], EXACT, &format!("box_at_{k}"));
            }
            for (case, q) in queries(&r, "box") {
                close(&b.closest_point(q).unwrap(), &nums(&r, &case, "closest"), EXACT, &case);
            }
        }

        // -- the rectangle, the triangle and the ray (plan B4, TestPlanarValues)

        const SHEAR: [f64; 16] = [1.0, 0.5, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];

        #[test]
        fn a_rectangle_is_a_curve_with_calls_of_its_own() {
            if !kernel_present() {
                return;
            }
            let r = Rectangle::new(&xy(), (1.0, 4.0), iv(0.0, 4.0)).unwrap();
            assert_eq!((r.x(), r.y(), r.frame()), (iv(1.0, 4.0), iv(0.0, 4.0), xy()));
            let curve = CurveValue::from(r);
            assert_eq!(curve.kind(), 9);
            assert_eq!((curve.point_at(2.25).unwrap(), r.point_at(9.0).unwrap()), ([3.25, 4.0, 0.0], [1.0, 0.0, 0.0]), "clamped to 4");
            assert_eq!((r.tangent_at(1.5).unwrap(), r.length().unwrap()), ([0.0, 1.0, 0.0], 14.0));
            assert_eq!(r.closest_point([2.0, -1.0, 7.0]).unwrap(), CurveFoot { t: 1.0 / 3.0, point: [2.0, 0.0, 0.0], unique: true });
            assert!(!Rectangle::new(&xy(), (0.0, 2.0), (0.0, 2.0)).unwrap().closest_point([1.0, 1.0, 0.0]).unwrap().unique, "the centre is a pick");
            assert_eq!(r.corners().unwrap(), [[1.0, 0.0, 0.0], [4.0, 0.0, 0.0], [4.0, 4.0, 0.0], [1.0, 4.0, 0.0]]);
            assert_eq!(r.area().unwrap(), 12.0);
            assert_eq!(r.closest_point_in([2.0, 1.0, 5.0], true).unwrap(), [2.0, 1.0, 0.0]);
            assert_eq!(r.closest_point_in([2.0, 1.0, 5.0], false).unwrap(), [1.0, 1.0, 0.0]);
            assert_eq!(r.bounds().unwrap(), ([1.0, 0.0, 0.0], [4.0, 4.0, 0.0]));
            assert_eq!(refused(Rectangle::new(&xy(), (1.0, 1.0), (0.0, 4.0))), "value_check: the x range must increase");
            assert_eq!(refused(Rectangle::from_values(&[&XY[..], &[1.0, 4.0, 0.0]].concat())), "value_check: a rectangle is 16 numbers, got 15");
            assert_eq!(
                refused(r.transform(&Transform::from_rows(&SHEAR).unwrap())),
                "value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)"
            );
            let scaled = r.transform(&Transform::scale_xyz(&xy(), 2.0, 3.0, 1.0).unwrap()).unwrap();
            assert_eq!(scaled, Rectangle::new(&xy(), (2.0, 8.0), (0.0, 12.0)).unwrap());
            let sheet = r.to_sheet().unwrap();
            let area = sheet.mass(1e-9).unwrap().area;
            assert!(sheet.faces().unwrap() == 1 && (area - 12.0).abs() <= 1e-9 * 12.0, "{area}");
            let ring = r.to_nurbs().unwrap();
            assert!(ring.degree() == 1 && ring.is_closed() && !ring.is_rational() && ring.domain().unwrap() == (0.0, 4.0));
            let p = ring.point(2.25).unwrap();
            assert!((p[0] - 3.25).abs() + (p[1] - 4.0).abs() + p[2].abs() <= 1e-12, "its parameter is t: {p:?}");
        }

        #[test]
        fn rectangle_contains_takes_none_as_its_effective_tolerance_and_zero_as_exact() {
            if !kernel_present() {
                return;
            }
            let r = Rectangle::new(&xy(), (1.0, 4.0), (0.0, 4.0)).unwrap(); // diagonal 5: effective 5e-4
            assert_eq!(r.contains([2.0, 2.0, 9.0], Some(0.0)).unwrap(), "inside");
            assert_eq!(r.contains([0.0, 2.0, 0.0], Some(0.0)).unwrap(), "outside");
            assert_eq!(r.contains([1.0, 2.0, 0.0], Some(0.0)).unwrap(), "on");
            let near = [1.0 - 4e-4, 2.0, 0.0];
            assert_eq!((r.contains(near, Some(0.0)).unwrap(), r.contains(near, Some(1e-3)).unwrap()), ("outside", "on"));
            assert_eq!((r.contains(near, None).unwrap(), r.contains(near, Some(f64::NAN)).unwrap()), ("on", "on"));
            assert_eq!(r.contains([1.0 - 6e-4, 2.0, 0.0], None).unwrap(), "outside");
            assert_eq!(refused(r.contains([0.0; 3], Some(-1.0))), "rectangle_contains: the tolerance must be finite and not negative");
            let eff = 1e-4 * 4.0 * 3f64.sqrt();
            let ball = Sphere::new(&xy(), 2.0).unwrap();
            assert!(ball.contains([2.0 + 0.9 * eff, 0.0, 0.0], f64::NAN).unwrap());
            assert!(!ball.contains([2.0 + 0.9 * eff, 0.0, 0.0], CONTAINS_TOLERANCE).unwrap());
            assert!(!ball.contains([2.0 + 1.1 * eff, 0.0, 0.0], f64::NAN).unwrap());
        }

        #[test]
        fn a_triangle_answers_its_closed_forms() {
            if !kernel_present() {
                return;
            }
            let t = Triangle::new([0.0; 3], [4.0, 0.0, 0.0], [0.0, 3.0, 0.0]).unwrap();
            assert_eq!((t.a(), t.b(), t.c()), ([0.0; 3], [4.0, 0.0, 0.0], [0.0, 3.0, 0.0]));
            assert_eq!((t.area().unwrap(), t.perimeter().unwrap()), (6.0, 12.0));
            close(&t.centroid().unwrap(), &[4.0 / 3.0, 1.0, 0.0], 1e-15, "centroid");
            let cc = t.circumcircle().unwrap();
            close(&cc.frame().origin(), &[2.0, 1.5, 0.0], 1e-15, "circumcircle centre");
            close(&[cc.radius()], &[2.5], 1e-15, "circumcircle radius");
            assert_eq!(t.point_at(0.5, 0.25, 0.25).unwrap(), [1.0, 0.75, 0.0]);
            close(&t.barycentric([1.0, 0.75, 5.0]).unwrap(), &[0.5, 0.25, 0.25], 1e-15, "barycentric");
            assert_eq!((t.closest_point([2.0, -1.0, 0.0]).unwrap(), t.closest_point([1.0, 1.0, 3.0]).unwrap()), ([2.0, 0.0, 0.0], [1.0, 1.0, 0.0]));
            assert_eq!(t.distance_to([1.0, 1.0, 3.0]).unwrap(), 3.0);
            assert_eq!(t.edge(1).unwrap(), Line::new([4.0, 0.0, 0.0], [0.0, 3.0, 0.0]).unwrap());
            assert_eq!(refused(t.edge(3)), "triangle_edge: edge 3 is not 0, 1 or 2");
            assert_eq!(
                refused(Triangle::new([0.0; 3], [1.0; 3], [2.0; 3])),
                "value_check: the triangle is degenerate (its points are collinear or coincident)"
            );
            assert_eq!(refused(Triangle::from_values(&[0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 3.0])), "value_check: a triangle is 9 numbers, got 8");
            let sheared = t.transform(&Transform::from_rows(&SHEAR).unwrap()).unwrap();
            assert_eq!(sheared, Triangle::new([0.0; 3], [4.0, 0.0, 0.0], [1.5, 3.0, 0.0]).unwrap(), "any affine map");
            let area = t.to_sheet().unwrap().mass(1e-9).unwrap().area;
            assert!((area - 6.0).abs() <= 1e-9 * 6.0, "{area}");
            assert_ne!(t, Triangle::new([0.0; 3], [0.0, 3.0, 0.0], [4.0, 0.0, 0.0]).unwrap());
            assert_eq!(hash_of(&t), hash_of(&Triangle::new(t.a(), t.b(), t.c()).unwrap()));
        }

        #[test]
        fn a_ray_holds_to_its_half_line_only_in_closest_point() {
            if !kernel_present() {
                return;
            }
            let ray = Ray::new([1.0, 2.0, 3.0], [0.0, 0.0, 2.0]).unwrap();
            assert_eq!((ray.values(), ray.position(), ray.direction()), ([1.0, 2.0, 3.0, 0.0, 0.0, 2.0], [1.0, 2.0, 3.0], [0.0, 0.0, 2.0]));
            assert_eq!((ray.point_at(1.5).unwrap(), ray.point_at(-1.0).unwrap()), ([1.0, 2.0, 6.0], [1.0, 2.0, 1.0]));
            assert_eq!(ray.closest_point([5.0, 2.0, 7.0]).unwrap(), CurveFoot { t: 2.0, point: [1.0, 2.0, 7.0], unique: true });
            assert_eq!(ray.closest_point([5.0, 2.0, -7.0]).unwrap(), CurveFoot { t: 0.0, point: [1.0, 2.0, 3.0], unique: true }, "behind: the start");
            close(&[ray.distance_to([5.0, 2.0, -7.0]).unwrap()], &[116f64.sqrt()], 1e-12, "distance");
            assert_eq!(refused(ray.bounds()), "value_bounds: a ray has no box (it is unbounded)");
            assert_eq!(refused(Ray::new([0.0; 3], [0.0; 3])), "value_check: the ray's direction is zero");
            assert_eq!(refused(Ray::from_values(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])), "value_check: a ray is 6 numbers, got 7");
            let scaled = ray.transform(&Transform::scale_xyz(&xy(), 1.0, 1.0, 3.0).unwrap()).unwrap();
            assert_eq!(scaled, Ray::new([1.0, 2.0, 9.0], [0.0, 0.0, 6.0]).unwrap());
        }

        #[test]
        fn rectangles_triangles_and_rays_match_rhino() {
            if !kernel_present() {
                return;
            }
            let r = vectors();
            let ranges = nums(&r, "rectangle", "ranges");
            let frame = Frame::of(nums(&r, "rectangle", "frame").try_into().unwrap()).unwrap();
            let rect = Rectangle::new(&frame, (ranges[0], ranges[1]), (ranges[2], ranges[3])).unwrap();
            let corners = nums(&r, "rectangle", "corners");
            for (k, c) in rect.corners().unwrap().iter().enumerate() {
                close(c, &corners[3 * k..3 * k + 3], EXACT, &format!("corner {k}"));
            }
            let want = [nums(&r, "rectangle", "area"), nums(&r, "rectangle", "circumference")].concat();
            close(&[rect.area().unwrap(), rect.length().unwrap()], &want, EXACT, "area and circumference");
            for k in 0..9 {
                let n = nums(&r, &format!("rectangle_at_{k}"), "point");
                close(&rect.point_at(n[0]).unwrap(), &n[1..4], EXACT, &format!("rectangle_at_{k}"));
            }
            let words = HashMap::from([("Inside", "inside"), ("Outside", "outside"), ("Coincident", "on")]);
            for (case, q) in queries(&r, "rectangle").into_iter().chain(queries(&r, "rectangle_in")) {
                close(&rect.closest_point(q).unwrap().point, &nums(&r, &case, "boundary"), EXACT, &case);
                close(&rect.closest_point_in(q, true).unwrap(), &nums(&r, &case, "filled"), EXACT, &case);
                let said = &r[&(case.clone(), "contains".to_string())][0];
                assert_eq!(rect.contains(q, Some(0.0)).unwrap(), words[said.as_str()], "{case}");
            }
            let p = nums(&r, "triangle", "points");
            let tri = Triangle::new(p3(&p[0..3]), p3(&p[3..6]), p3(&p[6..9])).unwrap();
            let want = [nums(&r, "triangle", "area"), nums(&r, "triangle", "perimeter")].concat();
            close(&[tri.area().unwrap(), tri.perimeter().unwrap()], &want, EXACT, "area and perimeter");
            close(&tri.centroid().unwrap(), &nums(&r, "triangle", "centroid"), EXACT, "centroid");
            close(&tri.circumcircle().unwrap().values(), &nums(&r, "triangle", "circumcircle"), EXACT, "circumcircle");
            for (case, q) in queries(&r, "triangle").into_iter().chain(queries(&r, "triangle_in")) {
                let w = tri.barycentric(q).unwrap();
                close(&w[1..], &nums(&r, &case, "barycentric")[..2], EXACT, &case);
                close(&tri.point_at(w[0], w[1], w[2]).unwrap(), &nums(&r, &case, "projected"), EXACT, &case);
                if w.iter().cloned().fold(f64::INFINITY, f64::min) < 0.0 {
                    close(&tri.closest_point(q).unwrap(), &nums(&r, &case, "boundary"), EXACT, &case);
                }
            }
            let rn = nums(&r, "ray", "ray");
            let ray = Ray::new(p3(&rn[0..3]), p3(&rn[3..6])).unwrap();
            for k in 0..4 {
                let n = nums(&r, &format!("ray_at_{k}"), "point");
                close(&ray.point_at(n[0]).unwrap(), &n[1..4], EXACT, &format!("ray_at_{k}"));
            }
        }
    }
}
