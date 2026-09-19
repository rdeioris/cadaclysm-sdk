//! The cadaclysm C ABI as Rust types.
//!
//! ```no_run
//! fn main() -> cadaclysm_sdk::Result<()> {
//!     let scene = cadaclysm_sdk::open("part.stp")?;
//!     println!("{} {} {}", scene.version(), scene.schema(), scene.metres_per_unit());
//!     for node in scene.walk() {
//!         println!("{}{} [{}]", "  ".repeat(node.depth() as usize), node.label(), node.kind());
//!     }
//!     Ok(())
//! }
//! ```
//!
//! This crate carries no cadaclysm source. It opens the prebuilt `cadaclysm_capi`
//! library when the program runs -- the one the Python, C#, Go, Java and Node
//! wrappers load -- and wraps the same object model they do: [`Scene`], [`Node`],
//! [`Placement`], [`Mesh`]. See [`sys::find_library`] for where it looks, or call
//! [`load`] with a path first.
//!
//! # Everything borrows from the scene
//!
//! Every pointer the ABI hands back points into the open document and dies with it.
//! The other wrappers document that and leave it to the caller; here the compiler
//! holds it. A [`Node`] borrows its [`Scene`], and a [`Mesh`] or [`Polylines`]
//! borrows the same scene through it, so their slices are the library's own memory,
//! uncopied, and a program that keeps one past the scene's end does not compile:
//!
//! ```compile_fail,E0505
//! let scene = cadaclysm_sdk::open("part.stp").unwrap();
//! let mesh = scene.roots()[0].mesh();
//! drop(scene); // error: `scene` is still borrowed by `mesh`
//! let _ = mesh.indices.len();
//! ```
//!
//! [`Mesh::copy`] makes arrays of the program's own, for the rare mesh that must
//! outlive its scene. Strings are copied into `String`s on the way out.
//!
//! Dropping a [`Scene`] closes it, so there is no closed scene to guard against: the
//! "a closed scene refuses" rules of the other wrappers cannot arise.
//!
//! # Threads
//!
//! A [`Scene`] is `Send` and `Sync`: every accessor of the ABI takes a `const` handle
//! and may be called concurrently, which is what lets [`Scene::realize_all`] run on
//! one thread while another reads [`Scene::realized`] or calls [`Scene::cancel`].

use std::ffi::{c_char, CStr, CString, OsStr};
use std::fmt;
use std::hash::{Hash, Hasher};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::ptr::NonNull;

mod loader;
pub mod blacksmith;
pub mod sys;

use sys::Api;

/// What the ABI returns for "no such node": a parent that is a root, an
/// `instance_of` that is not an instance. `CADACLYSM_NONE`, `u32::MAX`.
pub const NONE: u32 = sys::CADACLYSM_NONE;

/// OR into a convention: keep the preset's axes but the file's own units.
///
/// This crate's packing, as it is Python's: the ABI takes `file_units` as a field of
/// its open options, and [`OpenOptions::convention`] unpacks this bit into it, so
/// the one `u32` [`Convention::parse`] returns can carry it.
pub const FILE_UNITS: u32 = 0x100;

/// OR into a convention: ask for [`Mesh::uvs`], at one world unit per unit of `u`.
///
/// Off by default, as in the library -- a `(u, v)` is eight bytes a vertex. Even with
/// it, `uvs` is `None` for a node whose reader produces none. A format that stores
/// its own coordinates hands them back either way.
pub const UV_WORLD: u32 = 0x200;

// ---- errors -----------------------------------------------------------------------

/// A call into the library failed, carrying what it said about it -- or the library
/// could not be found or loaded at all.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    message: String,
}

impl Error {
    fn new(message: impl Into<String>) -> Error {
        Error { message: message.into() }
    }

    /// The library's own reason, as it gave it.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

/// This crate's result: every fallible call returns an [`Error`].
pub type Result<T> = std::result::Result<T, Error>;

fn api() -> Result<&'static Api> {
    sys::api().map_err(Error::new)
}

/// A borrowed `char *` as a `String`. Null and empty both come back as `""`.
///
/// # Safety
/// `raw` must be null or a NUL-terminated string that stays valid for this call.
unsafe fn text(raw: *const c_char) -> String {
    if raw.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned()
    }
}

/// What the library said about the last failure on this thread, or `""`.
fn last_error(api: &Api) -> String {
    unsafe { text((api.cadaclysm_last_error)()) }
}

/// `what` as a C string; an interior NUL is an error rather than a truncation.
fn c_string(what: &str, value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::new(format!("{what} contains a NUL byte: {value:?}")))
}

/// A path as the C string the ABI takes, which is UTF-8 on every platform.
fn c_path(path: &Path) -> Result<CString> {
    let text = path
        .to_str()
        .ok_or_else(|| Error::new(format!("{}: the library takes UTF-8 paths only", path.display())))?;
    c_string("path", text)
}

/// A slice over the library's memory, empty where the pointer is null.
///
/// # Safety
/// A non-null `pointer` must point at `count` valid, aligned `T`s that live for `'a`.
unsafe fn borrowed<'a, T>(pointer: *const T, count: usize) -> &'a [T] {
    if pointer.is_null() || count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(pointer, count) }
    }
}

/// `count` groups of `N` floats, or `None` where the pointer is null.
///
/// # Safety
/// As [`borrowed`], over `count * N` floats.
unsafe fn groups<'a, const N: usize>(pointer: *const f32, count: usize) -> Option<&'a [[f32; N]]> {
    (!pointer.is_null()).then(|| unsafe { borrowed(pointer.cast::<[f32; N]>(), count) })
}

/// A column-major 4x4 as rows, so `m[row][column]` reads as the textbooks write it.
fn rows<T: Copy + Into<f64>>(column_major: &[T; 16]) -> [[f64; 4]; 4] {
    let mut out = [[0.0; 4]; 4];
    for (column, chunk) in column_major.chunks_exact(4).enumerate() {
        for (row, value) in chunk.iter().enumerate() {
            out[row][column] = (*value).into();
        }
    }
    out
}

// ---- the library ------------------------------------------------------------------

/// Load the library from `path` before anything else asks for it.
///
/// Optional: the first call that needs the library loads it from where
/// [`sys::find_library`] finds it. Naming the library already loaded is a no-op;
/// naming another one is an error, since two copies cannot share a scene or a license.
pub fn load(path: impl AsRef<Path>) -> Result<()> {
    sys::load(Some(path.as_ref())).map(|_| ()).map_err(Error::new)
}

/// Where the library is: the one loaded, or the one the next call would load.
pub fn library_path() -> Result<PathBuf> {
    match sys::loaded_path() {
        Some(path) => Ok(path.to_path_buf()),
        None => sys::find_library().map_err(Error::new),
    }
}

/// The version of the library actually loaded, which is the one worth reporting.
pub fn version() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_version)()) })
}

/// When the loaded library was built, `YYYY-MM-DD`; a paid license covers every build
/// dated on or before its expiry.
pub fn build_date() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_build_date)()) })
}

/// Load a license: the certificate text, or the path of a file holding it.
///
/// Without this the library looks in `CADACLYSM_LICENSE`, then for `cadaclysm.lic`
/// beside the running executable and in the working directory. Fails with the
/// library's reason when the text does not verify; the previous license, if any,
/// stays in use.
pub fn license(text_or_path: impl AsRef<OsStr>) -> Result<()> {
    let api = api()?;
    let given = c_string("license", &text_or_path.as_ref().to_string_lossy())?;
    if unsafe { (api.cadaclysm_license_set)(given.as_ptr()) } {
        return Ok(());
    }
    let reason = last_error(api);
    Err(Error::new(if reason.is_empty() { "license refused".to_string() } else { reason }))
}

/// One line about the license the library is running under: the license line, or
/// `"unlicensed"` (`"unlicensed -- <reason>"` when one was found but did not verify).
pub fn license_info() -> Result<String> {
    let api = api()?;
    Ok(unsafe { text((api.cadaclysm_license_info)()) })
}

/// How many unlicensed notices the library has printed to stderr in this process. A
/// program without a stderr to watch can show its own banner by polling this.
pub fn license_notice_count() -> Result<u64> {
    let api = api()?;
    Ok(unsafe { (api.cadaclysm_license_notice_count)() })
}

/// One format [`Node::save_mesh`] writes: its name and the extension its files take,
/// which is not derivable (`stl-ascii` writes a `.stl`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeshFormat {
    pub name: String,
    pub extension: String,
}

/// Every format [`Node::save_mesh`] writes. Ask rather than hard-code: a format added
/// to the library turns up in a menu built from this without the program changing.
pub fn mesh_formats() -> Result<Vec<MeshFormat>> {
    let api = api()?;
    let count = unsafe { (api.cadaclysm_mesh_format_count)() };
    Ok((0..count)
        .map(|i| unsafe {
            MeshFormat {
                name: text((api.cadaclysm_mesh_format)(i)),
                extension: text((api.cadaclysm_mesh_format_extension)(i)),
            }
        })
        .collect())
}

/// Ask the user for a file to open, through the library's own dialog.
///
/// `None` if they cancelled, or if no dialog was available -- the ABI cannot tell
/// those apart. Blocks until the user acts; on macOS, call it from the main thread.
pub fn pick_file() -> Result<Option<PathBuf>> {
    let api = api()?;
    let raw = unsafe { (api.cadaclysm_pick_file)(std::ptr::null()) };
    // Borrowed until the next picker call on this thread, so copied out now.
    Ok((!raw.is_null()).then(|| PathBuf::from(unsafe { text(raw) })))
}

// ---- conventions and kinds --------------------------------------------------------

/// The coordinate space to open a file into -- `CadaclysmConvention`.
///
/// The library converts on the way out, so a caller names the space it draws in and
/// reads geometry already in it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum Convention {
    /// The file's own axes and its own units.
    #[default]
    Native = 0,
    /// Z up, left-handed, centimetres.
    Unreal = 1,
    /// Y up, left-handed, metres.
    Unity = 2,
    /// Y up, right-handed, metres -- glTF, three.js, Bevy, wgpu.
    YUp = 3,
    /// Z up, right-handed, metres.
    Blender = 4,
}

impl From<Convention> for u32 {
    fn from(convention: Convention) -> u32 {
        convention as u32
    }
}

impl Convention {
    /// A packed `u32` from a name a user typed: `"unreal"`, or `"unreal+file-units"`
    /// to keep the file's own units under the preset's axes.
    ///
    /// An unrecognised name is an error naming what is accepted, since one silently
    /// read as `Native` is the outcome that looks like success and draws the wrong space.
    pub fn parse(text: &str) -> Result<u32> {
        let lowered = text.trim().to_lowercase();
        let mut parts = lowered.split('+');
        let preset = parts.next().unwrap_or_default();
        let mut packed = match preset {
            "native" => Convention::Native,
            "unreal" => Convention::Unreal,
            "unity" => Convention::Unity,
            "y-up" => Convention::YUp,
            "blender" => Convention::Blender,
            _ => {
                return Err(Error::new(format!(
                    "no convention called {preset:?}: native, unreal, unity, y-up or blender"
                )))
            }
        } as u32;
        for flag in parts.filter(|flag| !flag.is_empty()) {
            if flag != "file-units" {
                return Err(Error::new(format!("no convention flag called {flag:?}: file-units")));
            }
            packed |= FILE_UNITS;
        }
        Ok(packed)
    }
}

/// Which kind of value an attribute holds. One-based in the ABI, zero meaning the
/// attribute was not there.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ValueKind {
    None,
    Text,
    Integer,
    Real,
    Boolean,
    /// The flat C struct cannot hold a list's elements, so the text carries a
    /// `[a, b, c]` rendering of them.
    List,
    /// Another entity, with the id the file gave (`#4`) as its text -- its own kind so
    /// a consumer can follow it rather than show it as prose.
    Reference,
}

impl ValueKind {
    fn from_raw(raw: i32) -> ValueKind {
        match raw {
            1 => ValueKind::Text,
            2 => ValueKind::Integer,
            3 => ValueKind::Real,
            4 => ValueKind::Boolean,
            5 => ValueKind::List,
            6 => ValueKind::Reference,
            _ => ValueKind::None,
        }
    }
}

// ---- the values the ABI hands over ------------------------------------------------

/// An axis-aligned box, or all zeros where there was nothing to bound.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Bounds {
    pub min: [f32; 3],
    pub max: [f32; 3],
}

impl Bounds {
    fn from_raw(raw: sys::CadaclysmBounds) -> Bounds {
        Bounds { min: raw.min, max: raw.max }
    }

    /// Whether this is the all-zero box the ABI uses for "nothing here".
    pub fn is_empty(&self) -> bool {
        self.min == [0.0; 3] && self.max == [0.0; 3]
    }

    pub fn size(&self) -> [f32; 3] {
        [0, 1, 2].map(|i| self.max[i] - self.min[i])
    }

    pub fn centre(&self) -> [f32; 3] {
        [0, 1, 2].map(|i| (self.min[i] + self.max[i]) / 2.0)
    }
}

/// An attribute's value, already the type its kind names. `List` and `Reference`
/// arrive as text.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    None,
    Text(String),
    Integer(i64),
    Real(f64),
    Boolean(bool),
}

/// One thing the file said about a node.
#[derive(Clone, Debug, PartialEq)]
pub struct Attribute {
    pub name: String,
    pub kind: ValueKind,
    pub value: Value,
}

impl Attribute {
    /// A `CadaclysmAttribute`, or `None` for the all-zero one past the end.
    ///
    /// **The kind picks exactly one field to read.** The others are zero, so reading
    /// the wrong one is silent: a text attribute read as `integer` is 0 on every node.
    unsafe fn from_raw(raw: &sys::CadaclysmAttribute) -> Option<Attribute> {
        // Null specifically: an attribute the file genuinely named "" is kept.
        if raw.name.is_null() {
            return None;
        }
        let kind = ValueKind::from_raw(raw.kind);
        let value = match kind {
            ValueKind::Text | ValueKind::List | ValueKind::Reference => Value::Text(unsafe { text(raw.text) }),
            ValueKind::Integer => Value::Integer(raw.integer),
            ValueKind::Real => Value::Real(raw.real),
            ValueKind::Boolean => Value::Boolean(raw.boolean),
            ValueKind::None => Value::None,
        };
        Some(Attribute { name: unsafe { text(raw.name) }, kind, value })
    }

    /// The value rendered for display, as cadaclysm's own Rust `Display` writes it --
    /// which, this being Rust, is what `f64`'s `Display` already does.
    pub fn text(&self) -> String {
        match &self.value {
            Value::None => String::new(),
            Value::Text(text) => text.clone(),
            Value::Integer(value) => value.to_string(),
            Value::Real(value) => value.to_string(),
            Value::Boolean(value) => value.to_string(),
        }
    }

    /// Whether the value reads as true, as Python's `bool()` would read it.
    fn truthy(&self) -> bool {
        match &self.value {
            Value::None => false,
            Value::Text(text) => !text.is_empty(),
            Value::Integer(value) => *value != 0,
            Value::Real(value) => *value != 0.0,
            Value::Boolean(value) => *value,
        }
    }
}

/// A node's triangles, in the node's own frame, borrowed from the scene.
///
/// `positions` and `indices` are empty for a node with no triangles; `normals`,
/// `uvs` and `colors` are `None` where the mesh carries none. `uvs` needs a scene
/// opened with [`UV_WORLD`] (or a format that stores its own); one unit of `u` is one
/// world unit, so faces' charts overlap -- a tiling material, not a lightmap. `colors`
/// is RGBA per vertex, only for a body painted in more than one colour opened with
/// [`OpenOptions::colors`].
#[derive(Clone, Copy, Debug)]
pub struct Mesh<'s> {
    pub positions: &'s [[f32; 3]],
    pub normals: Option<&'s [[f32; 3]]>,
    pub uvs: Option<&'s [[f32; 2]]>,
    pub colors: Option<&'s [[f32; 4]]>,
    /// Three to a triangle, into `positions`.
    pub indices: &'s [u32],
}

/// A [`Mesh`] in memory of the program's own, free of any scene.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshData {
    pub positions: Vec<[f32; 3]>,
    pub normals: Option<Vec<[f32; 3]>>,
    pub uvs: Option<Vec<[f32; 2]>>,
    pub colors: Option<Vec<[f32; 4]>>,
    pub indices: Vec<u32>,
}

impl<'s> Mesh<'s> {
    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn index_count(&self) -> usize {
        self.indices.len()
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }

    /// True for a node with no triangles -- a curve answers `can_mesh` and has none.
    pub fn is_empty(&self) -> bool {
        self.indices.is_empty() || self.positions.is_empty()
    }

    /// The same triangles in memory of the program's own, safe to outlive the scene.
    ///
    /// Expensive on purpose to be visible: this is where the gigabytes go on a large
    /// assembly, and it should be a line a reader can point at.
    pub fn copy(&self) -> MeshData {
        MeshData {
            positions: self.positions.to_vec(),
            normals: self.normals.map(<[_]>::to_vec),
            uvs: self.uvs.map(<[_]>::to_vec),
            colors: self.colors.map(<[_]>::to_vec),
            indices: self.indices.to_vec(),
        }
    }
}

/// A node's feature edges or free curves, already flattened to points, borrowed from
/// the scene: `positions` holds the runs end to end and `counts` says how long each is.
#[derive(Clone, Copy, Debug)]
pub struct Polylines<'s> {
    pub positions: &'s [[f32; 3]],
    pub counts: &'s [u32],
}

impl<'s> Polylines<'s> {
    fn from_raw(raw: sys::CadaclysmPolylines) -> Polylines<'s> {
        unsafe {
            Polylines {
                positions: groups::<3>(raw.positions, raw.vertex_count as usize).unwrap_or(&[]),
                counts: borrowed(raw.counts, raw.polyline_count as usize),
            }
        }
    }

    pub fn polyline_count(&self) -> usize {
        self.counts.len()
    }

    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.counts.is_empty() || self.positions.is_empty()
    }

    /// Each run as its own slice of points.
    pub fn iter(&self) -> impl Iterator<Item = &'s [[f32; 3]]> + 's {
        let positions = self.positions;
        let mut start = 0usize;
        self.counts.iter().map(move |&count| {
            let end = (start + count as usize).min(positions.len());
            let run = &positions[start.min(end)..end];
            start = end;
            run
        })
    }

    /// Indices into `positions` in endpoint pairs, one pair per segment: what
    /// `GL_LINES`, `LineList` and every other pair-taking API want, where the ABI
    /// hands over runs. A one-point run is a point, not a line, and yields nothing.
    pub fn segment_indices(&self) -> Vec<u32> {
        let mut pairs = Vec::new();
        let mut start = 0u32;
        for &count in self.counts {
            for i in 1..count {
                pairs.extend([start + i - 1, start + i]);
            }
            start += count;
        }
        pairs
    }

    /// The endpoint pairs themselves, two points per segment, in the node's own frame.
    pub fn segments(&self) -> Vec<[f32; 3]> {
        self.segment_indices().into_iter().filter_map(|i| self.positions.get(i as usize).copied()).collect()
    }
}

/// One trimmed face: the surface itself, plus the loops that cut it, borrowed from
/// the scene. See `CadaclysmFace` in the header for the whole story.
#[derive(Clone, Debug)]
pub struct Face<'s> {
    /// 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion,
    /// 7 NURBS, 8 sum -- [`Face::kind_name`] spells it.
    pub kind: u32,
    pub reversed: bool,
    pub transposed: bool,
    pub origin: [f32; 3],
    pub ax: [f32; 3],
    pub ay: [f32; 3],
    pub az: [f32; 3],
    /// `(u_min, v_min, u_max, v_max)`.
    pub domain: [f32; 4],
    /// Kind-dependent: radii, angles.
    pub scalars: [f32; 4],
    /// Each loop as `(u, v)` points, closing implicitly.
    pub loops: Vec<&'s [[f32; 2]]>,
    pub profile: &'s [[f32; 4]],
    pub profile2: &'s [[f32; 4]],
    pub nurbs: &'s [f32],
}

impl Face<'_> {
    pub fn kind_name(&self) -> &'static str {
        const NAMES: [&str; 9] = ["plane", "cylinder", "cone", "sphere", "torus", "revolution", "extrusion", "nurbs", "sum"];
        NAMES.get(self.kind as usize).copied().unwrap_or("unknown")
    }
}

/// A part's faces as surfaces and trims. **In the file's own frame**, unlike every
/// other product here -- see [`Scene::surface_matrix`].
#[derive(Clone, Debug, Default)]
pub struct Surfaces<'s> {
    pub faces: Vec<Face<'s>>,
}

impl<'s> Surfaces<'s> {
    pub fn len(&self) -> usize {
        self.faces.len()
    }

    pub fn is_empty(&self) -> bool {
        self.faces.is_empty()
    }

    pub fn iter(&self) -> std::slice::Iter<'_, Face<'s>> {
        self.faces.iter()
    }
}

impl<'s> IntoIterator for Surfaces<'s> {
    type Item = Face<'s>;
    type IntoIter = std::vec::IntoIter<Face<'s>>;
    fn into_iter(self) -> Self::IntoIter {
        self.faces.into_iter()
    }
}

/// A slice of `slice`, or empty where the range falls outside it.
fn window<T>(slice: &[T], start: u32, count: u32) -> &[T] {
    let start = start as usize;
    slice.get(start..start.saturating_add(count as usize)).unwrap_or(&[])
}

fn xyz(v: [f32; 4]) -> [f32; 3] {
    [v[0], v[1], v[2]]
}

// ---- breps ------------------------------------------------------------------------

/// A body's exact B-rep, shared with the scene by reference count rather than copied.
/// Dropping it gives the reference back; it outlives the scene for as long as it is held.
///
/// For the blacksmith library, which operates on it without a copy -- [`Brep::pointer`]
/// and [`Brep::layout_id`] are what that hands across -- and for asking whether it is
/// a manifold. In the node's own frame and **the file's own units and axes**, whatever
/// convention the scene was opened with.
pub struct Brep {
    pointer: NonNull<sys::CadaclysmBrep>,
    api: &'static Api,
}

// The library hands out an `Arc`: its reference count is atomic and the body behind
// it is immutable, so a reference may move and be shared across threads.
unsafe impl Send for Brep {}
unsafe impl Sync for Brep {}

impl Brep {
    /// How this library lays a brep out in memory: its compiler, target and source.
    /// The blacksmith library shares a brep only with a library whose id equals its own.
    pub fn layout_id() -> Result<String> {
        let api = api()?;
        Ok(unsafe { text((api.cadaclysm_brep_layout_id)()) })
    }

    /// The raw `const CadaclysmBrep *`, for handing to the blacksmith library.
    /// Valid for as long as this `Brep` is.
    pub fn pointer(&self) -> *const sys::CadaclysmBrep {
        self.pointer.as_ptr()
    }

    /// Whether its faces make a manifold, and whether it is closed. Read off the
    /// topology the file wrote, not a mesh: faces that name no shared edge read as
    /// open however well they meet in space.
    pub fn manifold(&self) -> Result<Manifold> {
        let mut out = [0u32; 8];
        if !unsafe { (self.api.cadaclysm_brep_manifold)(self.pointer(), out.as_mut_ptr()) } {
            let reason = last_error(self.api);
            return Err(Error::new(if reason.is_empty() { "manifold".to_string() } else { reason }));
        }
        Ok(Manifold::from_row(out))
    }

    /// Give the reference back now rather than at the end of scope.
    pub fn release(self) {}
}

impl Drop for Brep {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_brep_release)(self.pointer()) }
    }
}

impl fmt::Debug for Brep {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Brep({:p})", self.pointer)
    }
}

/// Whether a brep's faces make a manifold, as plain data ([`Brep::manifold`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Manifold {
    pub faces: u32,
    pub edges: u32,
    pub vertices: u32,
    /// Edges one face borders: a sheet's rim.
    pub boundary_edges: u32,
    /// Edges three or more faces border.
    pub non_manifold_edges: u32,
    /// Vertices whose faces make more than one fan (two solids touching at a corner).
    pub non_manifold_vertices: u32,
    /// No non-manifold edge or vertex.
    pub is_manifold: bool,
    /// Manifold with no boundary edge either: it encloses a solid.
    pub is_closed: bool,
}

impl Manifold {
    fn from_row(row: [u32; 8]) -> Manifold {
        Manifold {
            faces: row[0],
            edges: row[1],
            vertices: row[2],
            boundary_edges: row[3],
            non_manifold_edges: row[4],
            non_manifold_vertices: row[5],
            is_manifold: row[6] != 0,
            is_closed: row[7] != 0,
        }
    }
}

// ---- placements -------------------------------------------------------------------

/// One drawing of one node's geometry, at one place.
///
/// **A node is not a drawing.** Most nodes are structure and draw nothing, and a
/// block's members draw once per placement of it rather than once on their own
/// account. Iterate [`Scene::placements`] to draw, and nodes to build a tree.
#[derive(Clone, Copy)]
pub struct Placement<'s> {
    scene: &'s Scene,
    index: u32,
}

impl<'s> Placement<'s> {
    pub fn scene(&self) -> &'s Scene {
        self.scene
    }

    pub fn index(&self) -> u32 {
        self.index
    }

    /// The node whose mesh, edges and curves this draws. Two drawings of one shape
    /// name the same node, and so hand back the same arrays to upload once.
    pub fn geometry(&self) -> Node<'s> {
        let index = unsafe { (self.scene.api.cadaclysm_placement_geometry)(self.scene.raw(), self.index) };
        Node { scene: self.scene, index }
    }

    /// What a click on this drawing should select: the placement rather than the
    /// shape it draws, which is shared with every sibling copy.
    pub fn select(&self) -> Node<'s> {
        let index = unsafe { (self.scene.api.cadaclysm_placement_select)(self.scene.raw(), self.index) };
        Node { scene: self.scene, index }
    }

    /// Where to draw it, as rows (`m[row][column]`), composed through every frame
    /// between the document's root and this drawing.
    pub fn transform(&self) -> [[f64; 4]; 4] {
        rows(&self.raw_transform())
    }

    /// The same matrix in the ABI's own column-major order -- what `glam`'s
    /// `Mat4::from_cols_array` and a GPU uniform take.
    pub fn raw_transform(&self) -> [f64; 16] {
        let mut out = [0.0; 16];
        unsafe { (self.scene.api.cadaclysm_placement_transform)(self.scene.raw(), self.index, out.as_mut_ptr()) };
        out
    }
}

impl fmt::Debug for Placement<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Placement(index={}, geometry={})", self.index, self.geometry().index)
    }
}

// ---- nodes ------------------------------------------------------------------------

/// One node of the document: an assembly, a shape, a placement.
///
/// A handle rather than a snapshot: every method asks the scene when called, so
/// nothing here goes stale and nothing is built that a caller never asks for. That
/// matters -- `bounds` and `mesh` *build* the geometry, and a tree of ten thousand
/// nodes should cost ten thousand names, not ten thousand tessellations.
#[derive(Clone, Copy)]
pub struct Node<'s> {
    scene: &'s Scene,
    index: u32,
}

// Identity is the pair, so the same node from two lookups is equal and can key a map.
impl PartialEq for Node<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index && std::ptr::eq(self.scene, other.scene)
    }
}

impl Eq for Node<'_> {}

impl Hash for Node<'_> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.scene as *const Scene).hash(state);
        self.index.hash(state);
    }
}

impl fmt::Debug for Node<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = self.name();
        let kind = self.kind();
        let label = if !name.is_empty() { name } else if !kind.is_empty() { kind } else { "?".into() };
        write!(f, "<Node {} {}>", self.index, label)
    }
}

impl<'s> Node<'s> {
    pub fn scene(&self) -> &'s Scene {
        self.scene
    }

    pub fn index(&self) -> u32 {
        self.index
    }

    fn call<T>(&self, function: unsafe extern "C" fn(*const sys::CadaclysmScene, u32) -> T) -> T {
        unsafe { function(self.scene.raw(), self.index) }
    }

    fn string(&self, function: unsafe extern "C" fn(*const sys::CadaclysmScene, u32) -> *const c_char) -> String {
        unsafe { text(self.call(function)) }
    }

    pub fn name(&self) -> String {
        self.string(self.scene.api.cadaclysm_node_name)
    }

    /// What the file calls it -- a STEP `#N`, an IFC GlobalId, a Rhino UUID. Text,
    /// because a 22-character GlobalId does not fit in an integer.
    pub fn id(&self) -> String {
        self.string(self.scene.api.cadaclysm_node_id)
    }

    /// What the file calls its type -- an IFC type, an openNURBS class, a shape kind.
    pub fn kind(&self) -> String {
        self.string(self.scene.api.cadaclysm_node_kind)
    }

    /// Whether the file says to show this when it is opened. **Not inherited**: a
    /// layer switched off does not change its members' answer -- see [`Node::visible_now`].
    /// `true` where the format says nothing, so a `false` is always the file's own.
    pub fn visible(&self) -> bool {
        self.call(self.scene.api.cadaclysm_node_visible)
    }

    /// [`Node::visible`] with every ancestor consulted, which is what Rhino shows.
    pub fn visible_now(&self) -> bool {
        let mut node = Some(*self);
        while let Some(current) = node {
            if !current.visible() {
                return false;
            }
            node = current.parent();
        }
        true
    }

    /// Whether the file says this cannot be selected or edited (Rhino's idea; `false`
    /// elsewhere). Locking is not hiding: a locked thing draws as any other.
    pub fn locked(&self) -> bool {
        self.attributes().iter().find(|a| a.name == "Locked").is_some_and(Attribute::truthy)
    }

    /// Something to put in a tree row: the name, else the kind, else `#index`.
    pub fn label(&self) -> String {
        let name = self.name();
        if !name.is_empty() {
            return name;
        }
        let kind = self.kind();
        if !kind.is_empty() {
            return kind;
        }
        format!("#{}", self.index)
    }

    /// How far down the tree it sits, a root being zero.
    pub fn depth(&self) -> u32 {
        self.call(self.scene.api.cadaclysm_node_depth)
    }

    /// What its geometry was before it was triangles -- `brep`, `mesh`, `csg` -- or
    /// empty for a node that draws nothing.
    pub fn generator(&self) -> String {
        self.string(self.scene.api.cadaclysm_node_generator)
    }

    /// The node containing this one, or `None` for a root.
    pub fn parent(&self) -> Option<Node<'s>> {
        self.scene.node_or_none(self.call(self.scene.api.cadaclysm_node_parent))
    }

    pub fn children(&self) -> Vec<Node<'s>> {
        let api = self.scene.api;
        let count = self.call(api.cadaclysm_node_child_count);
        (0..count)
            .map(|i| Node { scene: self.scene, index: unsafe { (api.cadaclysm_node_child)(self.scene.raw(), self.index, i) } })
            .collect()
    }

    /// The node whose geometry this one is a placement of, or `None`: a shell placed
    /// seventy-four times is one mesh and seventy-four transforms.
    pub fn instance_of(&self) -> Option<Node<'s>> {
        self.scene.node_or_none(self.call(self.scene.api.cadaclysm_node_instance_of))
    }

    /// What a click on this node's geometry should select -- itself, usually; an IFC
    /// representation item points back at its product.
    pub fn select_as(&self) -> Node<'s> {
        let chosen = self.call(self.scene.api.cadaclysm_node_select_as);
        if chosen == NONE {
            *self
        } else {
            Node { scene: self.scene, index: chosen }
        }
    }

    /// Everything the file said about this node.
    pub fn attributes(&self) -> Vec<Attribute> {
        let api = self.scene.api;
        let count = self.call(api.cadaclysm_node_attribute_count);
        (0..count)
            .filter_map(|i| unsafe {
                let raw = (api.cadaclysm_node_attribute)(self.scene.raw(), self.index, i);
                Attribute::from_raw(&raw)
            })
            .collect()
    }

    /// Whether this node has geometry of its own to show. Builds nothing.
    pub fn can_mesh(&self) -> bool {
        self.call(self.scene.api.cadaclysm_node_can_mesh)
    }

    /// Write this node's own mesh -- where it is defined, without its placement -- to
    /// `path` in `format`, one of [`mesh_formats`]. Fails for a node that draws
    /// nothing, or a format the library does not write.
    pub fn save_mesh(&self, path: impl AsRef<Path>, format: &str) -> Result<()> {
        let path = path.as_ref();
        let (c_path, c_format) = (c_path(path)?, c_string("format", format)?);
        let api = self.scene.api;
        if unsafe { (api.cadaclysm_node_save_mesh)(self.scene.raw(), self.index, c_path.as_ptr(), c_format.as_ptr()) } {
            return Ok(());
        }
        let reason = last_error(api);
        Err(Error::new(if reason.is_empty() { format!("could not write {}", path.display()) } else { reason }))
    }

    /// `[r, g, b, a]` if the file gave one. `None` rather than a default: most STEP
    /// files carry no colour, and the honest answer lets the caller use its own.
    pub fn colour(&self) -> Option<[f32; 4]> {
        let mut rgba = [0.0f32; 4];
        unsafe { (self.scene.api.cadaclysm_node_color)(self.scene.raw(), self.index, rgba.as_mut_ptr()) }.then_some(rgba)
    }

    /// Where this node's geometry sits, as rows (`m[row][column]`). Doubles while the
    /// mesh is floats, on purpose: an f32 mesh about its own origin under an f64
    /// transform keeps the millimetres a building at UTM coordinates would lose.
    pub fn transform(&self) -> [[f64; 4]; 4] {
        rows(&self.raw_transform())
    }

    /// The same matrix in the ABI's own column-major order.
    pub fn raw_transform(&self) -> [f64; 16] {
        let mut out = [0.0; 16];
        unsafe { (self.scene.api.cadaclysm_node_transform)(self.scene.raw(), self.index, out.as_mut_ptr()) };
        out
    }

    /// The extent of the geometry this node draws, **in that geometry's own frame**.
    /// Builds the geometry if it has not been built.
    pub fn bounds(&self) -> Bounds {
        Bounds::from_raw(self.call(self.scene.api.cadaclysm_node_bounds))
    }

    /// Its triangles, in their own frame, built now if they have not been. Where the
    /// node instances another, these are the instanced node's triangles -- two
    /// occurrences of one shape hand back the *same* slices.
    pub fn mesh(&self) -> Mesh<'s> {
        let raw = self.call(self.scene.api.cadaclysm_node_mesh);
        let n = raw.vertex_count as usize;
        // SAFETY: the scene keeps every mesh it built until it closes, and `'s`
        // borrows the scene, so these slices cannot outlive the memory.
        unsafe {
            Mesh {
                positions: groups::<3>(raw.positions, n).unwrap_or(&[]),
                normals: groups::<3>(raw.normals, n),
                uvs: groups::<2>(raw.uvs, n),
                colors: groups::<4>(raw.colors, n),
                indices: borrowed(raw.indices, raw.index_count as usize),
            }
        }
    }

    /// Its faces as surfaces and trim loops, where the reader built them. Costs
    /// [`Node::mesh`] nothing; empty where the reader has no parametric read.
    pub fn surfaces(&self) -> Surfaces<'s> {
        let raw = self.call(self.scene.api.cadaclysm_node_surfaces);
        // SAFETY: as `mesh` -- the scene keeps what it built.
        let (faces, loops, points, profiles, nurbs) = unsafe {
            (
                borrowed(raw.faces, raw.face_count as usize),
                borrowed(raw.loops.cast::<[u32; 2]>(), raw.loop_count as usize),
                groups::<2>(raw.points, raw.point_count as usize).unwrap_or(&[]),
                groups::<4>(raw.profiles, raw.profile_count as usize).unwrap_or(&[]),
                borrowed(raw.nurbs, raw.nurbs_count as usize),
            )
        };
        let faces = faces
            .iter()
            .map(|f| Face {
                kind: f.kind,
                reversed: f.reversed != 0,
                transposed: f.transposed != 0,
                origin: xyz(f.origin),
                ax: xyz(f.ax),
                ay: xyz(f.ay),
                az: xyz(f.az),
                domain: f.domain,
                scalars: f.scalars,
                loops: window(loops, f.loop_start, f.loop_count)
                    .iter()
                    .map(|&[start, length]| window(points, start, length))
                    .collect(),
                profile: window(profiles, f.profile_start, f.profile_count),
                profile2: window(profiles, f.profile2_start, f.profile2_count),
                nurbs: window(nurbs, f.nurbs_start, f.nurbs_count),
            })
            .collect();
        Surfaces { faces }
    }

    /// Its exact B-rep, or `None` where it has none (a mesh, a curve, a CSG body, a JT
    /// or OpenSCAD part). Shared with the scene, not copied; see [`Brep`].
    pub fn brep(&self) -> Option<Brep> {
        let pointer = self.call(self.scene.api.cadaclysm_node_brep);
        NonNull::new(pointer.cast_mut()).map(|pointer| Brep { pointer, api: self.scene.api })
    }

    /// Its feature edges, as polylines to draw an overlay from.
    pub fn edges(&self) -> Polylines<'s> {
        Polylines::from_raw(self.call(self.scene.api.cadaclysm_node_edges))
    }

    /// Its free curves, as polylines. A 2D drawing is all of these.
    pub fn curves(&self) -> Polylines<'s> {
        Polylines::from_raw(self.call(self.scene.api.cadaclysm_node_curves))
    }

    /// Its interior surface lines, as polylines: these rule across the faces `edges`
    /// bound, so a curved face reads as curved. A flat face yields its outline here.
    pub fn isocurves(&self) -> Polylines<'s> {
        Polylines::from_raw(self.call(self.scene.api.cadaclysm_node_isocurves))
    }

    /// This node and every node under it, parents before children.
    pub fn walk(&self) -> Walk<'s> {
        Walk { stack: vec![*self] }
    }
}

/// A depth-first walk, parents before children, from [`Node::walk`] or [`Scene::walk`].
pub struct Walk<'s> {
    stack: Vec<Node<'s>>,
}

impl<'s> Iterator for Walk<'s> {
    type Item = Node<'s>;
    fn next(&mut self) -> Option<Node<'s>> {
        let node = self.stack.pop()?;
        self.stack.extend(node.children().into_iter().rev());
        Some(node)
    }
}

// ---- the scene --------------------------------------------------------------------

/// An open document, closed when dropped. Everything it hands back borrows from it.
pub struct Scene {
    handle: NonNull<sys::CadaclysmScene>,
    api: &'static Api,
    path: PathBuf,
    schema_path: Option<PathBuf>,
    convention: u32,
}

// The ABI's accessors all take a `const` handle and may run concurrently -- the
// library asserts its scene is `Sync` at compile time -- and closing takes `self`.
unsafe impl Send for Scene {}
unsafe impl Sync for Scene {}

impl Drop for Scene {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_close)(self.handle.as_ptr()) }
    }
}

impl fmt::Debug for Scene {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        write!(f, "<Scene {name} ({} nodes)>", self.len())
    }
}

impl Scene {
    fn raw(&self) -> *const sys::CadaclysmScene {
        self.handle.as_ptr()
    }

    fn node_or_none(&self, index: u32) -> Option<Node<'_>> {
        (index != NONE).then_some(Node { scene: self, index })
    }

    /// Close it now rather than at the end of scope.
    pub fn close(self) {}

    /// The file this was read from, or the name an in-memory scene was given.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The `.exp` it was opened with, where one was given.
    pub fn schema_path(&self) -> Option<&Path> {
        self.schema_path.as_deref()
    }

    /// The packed `u32` it was opened with -- a [`Convention`] OR'd with
    /// [`FILE_UNITS`] and [`UV_WORLD`]. Every array out of this scene is in it.
    pub fn convention(&self) -> u32 {
        self.convention
    }

    /// The version of the library that read it.
    pub fn version(&self) -> String {
        unsafe { text((self.api.cadaclysm_version)()) }
    }

    /// The schema the file named, or `""` for a format that names none.
    pub fn schema(&self) -> String {
        unsafe { text((self.api.cadaclysm_schema)(self.raw())) }
    }

    /// The schema that actually read it, which is not always the one it named: a file
    /// declaring `IFC4X3_RC2` reads under `IFC4X3_ADD2`. See [`Scene::substituted`].
    pub fn schema_read(&self) -> String {
        unsafe { text((self.api.cadaclysm_schema_read)(self.raw())) }
    }

    /// Whether something other than the file's own schema read it, compared on the
    /// *bare* names: `AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }` is not a substitution.
    pub fn substituted(&self) -> bool {
        let read = self.schema_read();
        if read.is_empty() {
            return false;
        }
        let bare = |entry: &str| entry.split('{').next().unwrap_or("").trim().trim_matches('.').to_lowercase();
        let read = bare(&read);
        !self.schema().split(',').any(|part| bare(part) == read)
    }

    /// What one length in the file is worth in metres, or 1 where it did not say.
    pub fn metres_per_unit(&self) -> f64 {
        unsafe { (self.api.cadaclysm_metres_per_unit)(self.raw()) }
    }

    /// Everything the model covers, **in world coordinates** -- the one figure here
    /// not in a node's own frame. **This meshes all of it.**
    pub fn bounds(&self) -> Bounds {
        Bounds::from_raw(unsafe { (self.api.cadaclysm_bounds)(self.raw()) })
    }

    /// The 4x4, as rows, that puts [`Node::surfaces`] in the space everything else is
    /// already in. Only the surfaces need it; for a scene opened `Native` at the
    /// file's own units it is the identity.
    pub fn surface_matrix(&self) -> [[f64; 4]; 4] {
        let mut out = [0.0f32; 16];
        unsafe { (self.api.cadaclysm_surface_matrix)(self.raw(), out.as_mut_ptr()) };
        rows(&out)
    }

    /// What this file held that the reader could not build.
    pub fn diagnostics(&self) -> Vec<String> {
        let count = unsafe { (self.api.cadaclysm_diagnostic_count)(self.raw()) };
        (0..count).map(|i| unsafe { text((self.api.cadaclysm_diagnostic)(self.raw(), i)) }).collect()
    }

    /// The archive member this was read from, or `None` for a plain file: `open` on a
    /// `.zip` chooses one member, and this is the only way to learn which.
    pub fn source_name(&self) -> Option<String> {
        let raw = unsafe { (self.api.cadaclysm_source_name)(self.raw()) };
        (!raw.is_null()).then(|| unsafe { text(raw) })
    }

    /// How many nodes it has, geometry or not.
    pub fn len(&self) -> usize {
        unsafe { (self.api.cadaclysm_node_count)(self.raw()) as usize }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The node at `index`, or `None` past the end.
    pub fn node(&self, index: u32) -> Option<Node<'_>> {
        ((index as usize) < self.len()).then_some(Node { scene: self, index })
    }

    /// Every node in index order, without building a list of them.
    pub fn iter(&self) -> impl Iterator<Item = Node<'_>> + '_ {
        (0..self.len() as u32).map(move |index| Node { scene: self, index })
    }

    /// Every node, in index order.
    pub fn nodes(&self) -> Vec<Node<'_>> {
        self.iter().collect()
    }

    /// The indices of the nodes a filter matches, in document order.
    ///
    /// The filter is one boolean expression over a node --
    /// `class == ON_Brep and within(class == ON_Layer and name == Walls)`. Fails with
    /// the parser's own message where it will not parse; matching nothing is `Ok(vec![])`.
    pub fn query(&self, filter: &str) -> Result<Vec<u32>> {
        let encoded = c_string("filter", filter)?;
        let api = self.api;
        // Sized first, then filled: the ABI cannot hand back an allocation this side
        // would have to free, so it counts on request and writes on demand.
        let total = unsafe { (api.cadaclysm_query)(self.raw(), encoded.as_ptr(), std::ptr::null_mut(), 0) };
        if total == 0 {
            let reason = last_error(api);
            if reason.is_empty() {
                return Ok(Vec::new());
            }
            return Err(Error::new(format!("{}: {reason}", self.file_name())));
        }
        let mut out = vec![0u32; total as usize];
        let written = unsafe { (api.cadaclysm_query)(self.raw(), encoded.as_ptr(), out.as_mut_ptr(), total) };
        out.truncate(written.min(total) as usize);
        Ok(out)
    }

    /// What this document draws and where -- see [`Placement`]. **Not the nodes**:
    /// this is the list to iterate to draw.
    pub fn placements(&self) -> Vec<Placement<'_>> {
        let count = unsafe { (self.api.cadaclysm_placement_count)(self.raw()) };
        (0..count).map(|index| Placement { scene: self, index }).collect()
    }

    /// The nodes nothing else contains.
    pub fn roots(&self) -> Vec<Node<'_>> {
        let count = unsafe { (self.api.cadaclysm_root_count)(self.raw()) };
        (0..count)
            .filter_map(|i| self.node_or_none(unsafe { (self.api.cadaclysm_root)(self.raw(), i) }))
            .collect()
    }

    /// Every node reachable from the roots, parents before children.
    pub fn walk(&self) -> impl Iterator<Item = Node<'_>> + '_ {
        self.roots().into_iter().flat_map(|root| root.walk())
    }

    /// Build every mesh now, across threads, and say how many were built. Watch it
    /// from another thread with [`Scene::realized`] and [`Scene::realize_total`], or
    /// stop it with [`Scene::cancel`].
    pub fn realize_all(&self) -> u32 {
        unsafe { (self.api.cadaclysm_realize_all)(self.raw()) }
    }

    /// How many nodes `realize_all` has finished with.
    pub fn realized(&self) -> u32 {
        unsafe { (self.api.cadaclysm_realized)(self.raw()) }
    }

    /// How many there will be in all -- zero until `realize_all` starts.
    pub fn realize_total(&self) -> u32 {
        unsafe { (self.api.cadaclysm_realize_total)(self.raw()) }
    }

    /// Ask a running `realize_all` to stop. **One-way, for the life of the scene**:
    /// every later `realize_all` returns 0 at once. Meshes stay available node by node.
    pub fn cancel(&self) {
        unsafe { (self.api.cadaclysm_cancel)(self.raw()) }
    }

    /// Write the whole scene to `path`: `"glb"`, `"gltf"` or `"obj"` -- every placement
    /// of every shape, named and placed as the tree is, in the convention it was opened
    /// with. [`Node::save_mesh`] writes one node's mesh on its own instead.
    pub fn save(&self, path: impl AsRef<Path>, format: &str) -> Result<()> {
        let path = path.as_ref();
        let (c_path, c_format) = (c_path(path)?, c_string("format", format)?);
        if unsafe { (self.api.cadaclysm_scene_save)(self.raw(), c_path.as_ptr(), c_format.as_ptr()) } {
            return Ok(());
        }
        let reason = last_error(self.api);
        Err(Error::new(if reason.is_empty() { format!("could not write {}", path.display()) } else { reason }))
    }

    fn file_name(&self) -> String {
        self.path.file_name().unwrap_or(self.path.as_os_str()).to_string_lossy().into_owned()
    }
}

// ---- opening ----------------------------------------------------------------------

/// A schema path as a C string, and the one-entry array pointing at it.
type HeldSchema = Option<(CString, [*const c_char; 1])>;

/// How to open a file: the space to read it into, an extra schema, per-vertex colours.
///
/// ```no_run
/// use cadaclysm_sdk::{Convention, OpenOptions, UV_WORLD};
/// let scene = OpenOptions::new().convention(Convention::YUp as u32 | UV_WORLD).open("part.stp")?;
/// # Ok::<(), cadaclysm_sdk::Error>(())
/// ```
#[derive(Clone, Debug, Default)]
pub struct OpenOptions {
    convention: u32,
    schema: Option<PathBuf>,
    colors: bool,
    source_metres_per_unit: f64,
    name: Option<String>,
}

impl OpenOptions {
    pub fn new() -> OpenOptions {
        OpenOptions::default()
    }

    /// The space to read the file into: a [`Convention`], optionally OR'd with
    /// [`FILE_UNITS`] and [`UV_WORLD`]. The library does the converting. The default
    /// keeps the file's own axes and units.
    pub fn convention(mut self, packed: impl Into<u32>) -> OpenOptions {
        self.convention = packed.into();
        self
    }

    /// An EXPRESS schema (`.exp`) beyond the ones built into the library, or a
    /// directory of them the library chooses from by what each declares. Every schema
    /// the project ships is compiled in, so a STEP or IFC file opens without one.
    pub fn schema(mut self, path: impl Into<PathBuf>) -> OpenOptions {
        self.schema = Some(path.into());
        self
    }

    /// Per-vertex colours ([`Mesh::colors`]) for a body painted in more than one colour.
    pub fn colors(mut self, yes: bool) -> OpenOptions {
        self.colors = yes;
        self
    }

    /// What one of the file's lengths is worth in metres, for a format that does not
    /// say (STL, OBJ); zero takes the reader's own answer.
    pub fn source_metres_per_unit(mut self, metres: f64) -> OpenOptions {
        self.source_metres_per_unit = metres;
        self
    }

    /// The name an in-memory scene reports as its [`Scene::path`]; `<memory>` otherwise.
    pub fn name(mut self, name: impl Into<String>) -> OpenOptions {
        self.name = Some(name.into());
        self
    }

    /// The ABI's struct, and the schema string it points into -- which must outlive
    /// the call it is passed to.
    fn raw(&self) -> Result<(sys::CadaclysmOpenOptions, HeldSchema)> {
        let held = match &self.schema {
            Some(schema) => {
                let encoded = c_path(schema)?;
                let array = [encoded.as_ptr()];
                Some((encoded, array))
            }
            None => None,
        };
        let options = sys::CadaclysmOpenOptions {
            // Our own layout's size, never the library's: see `sys::CadaclysmOpenOptions`.
            size: std::mem::size_of::<sys::CadaclysmOpenOptions>(),
            convention: self.convention & !(FILE_UNITS | UV_WORLD),
            spec: std::ptr::null(),
            file_units: self.convention & FILE_UNITS != 0,
            uvs: u32::from(self.convention & UV_WORLD != 0),
            colors: u32::from(self.colors),
            source_meters_per_unit: self.source_metres_per_unit,
            schemas: std::ptr::null(),
            schema_count: 0,
            schema_text: std::ptr::null(),
            schema_length: 0,
            pick: std::ptr::null(),
            pick_user: std::ptr::null_mut(),
        };
        Ok((options, held))
    }

    fn scene(&self, api: &'static Api, pointer: *mut sys::CadaclysmScene, path: PathBuf, what: &str) -> Result<Scene> {
        match NonNull::new(pointer) {
            Some(handle) => Ok(Scene { handle, api, path, schema_path: self.schema.clone(), convention: self.convention }),
            None => Err(Error::new(format!("{what}: {}", last_error(api)))),
        }
    }

    fn check_schema(&self) -> Result<()> {
        match &self.schema {
            Some(schema) if !schema.exists() => {
                Err(Error::new(format!("schema {} is neither a file nor a directory", schema.display())))
            }
            _ => Ok(()),
        }
    }

    /// Open a CAD file. A `.zip` opens its first readable member; [`Scene::source_name`]
    /// says which. An unrecognised convention is an error, never read as `Native`.
    pub fn open(&self, path: impl AsRef<Path>) -> Result<Scene> {
        let path = path.as_ref();
        if !path.exists() {
            return Err(Error::new(format!("{}: no such file", path.display())));
        }
        self.check_schema()?;
        let api = api()?;
        let c_path = c_path(path)?;
        let (mut options, held) = self.raw()?;
        if let Some((_, array)) = &held {
            options.schemas = array.as_ptr();
            options.schema_count = 1;
        }
        let pointer = unsafe { (api.cadaclysm_open)(c_path.as_ptr(), &options) };
        drop(held);
        let name = path.file_name().unwrap_or(path.as_os_str()).to_string_lossy().into_owned();
        self.scene(api, pointer, path.to_path_buf(), &name)
    }

    /// Open a CAD file already in bytes. `format` names the kind as an extension
    /// would -- `"step"`, `"ifc"`, `"3dm"`, `"scad"` -- a leading dot allowed.
    pub fn open_memory(&self, data: &[u8], format: &str) -> Result<Scene> {
        self.check_schema()?;
        let api = api()?;
        let c_format = c_string("format", format)?;
        let (mut options, held) = self.raw()?;
        if let Some((_, array)) = &held {
            options.schemas = array.as_ptr();
            options.schema_count = 1;
        }
        let pointer = unsafe { (api.cadaclysm_open_memory)(data.as_ptr(), data.len(), c_format.as_ptr(), &options) };
        drop(held);
        let name = self.name.clone().unwrap_or_else(|| "<memory>".to_string());
        self.scene(api, pointer, PathBuf::from(&name), &name)
    }
}

/// Open a CAD file into its own axes and units. [`OpenOptions`] chooses otherwise.
pub fn open(path: impl AsRef<Path>) -> Result<Scene> {
    OpenOptions::new().open(path)
}

/// Open a CAD file already in bytes; `format` names its kind as an extension would.
pub fn open_memory(data: &[u8], format: &str) -> Result<Scene> {
    OpenOptions::new().open_memory(data, format)
}

// ---- schemas ----------------------------------------------------------------------

/// The schema a STEP or IFC file says it speaks, from `FILE_SCHEMA` in its own header.
/// Reads a few kilobytes, so a 300 MB IFC costs nothing to ask. `""` where none is named.
pub fn declared_schema(model: impl AsRef<Path>) -> Result<String> {
    let model = model.as_ref();
    let mut head = Vec::with_capacity(8192);
    std::fs::File::open(model)
        .and_then(|file| file.take(8192).read_to_end(&mut head))
        .map_err(|e| Error::new(format!("{}: {e}", model.display())))?;
    // Latin-1: every byte is a character, so no header is refused for its encoding.
    let head: String = head.iter().map(|&b| b as char).collect();
    Ok(file_schema(&head).unwrap_or_default())
}

/// The first name in `FILE_SCHEMA (('NAME'` of `head`, matched case-insensitively.
fn file_schema(head: &str) -> Option<String> {
    let upper = head.to_ascii_uppercase();
    let mut from = 0;
    while let Some(found) = upper[from..].find("FILE_SCHEMA") {
        let after = from + found + "FILE_SCHEMA".len();
        let mut rest = head[after..].trim_start();
        let mut matched = true;
        for expected in ['(', '(', '\''] {
            match rest.strip_prefix(expected) {
                Some(tail) => rest = if expected == '\'' { tail } else { tail.trim_start() },
                None => {
                    matched = false;
                    break;
                }
            }
        }
        if matched {
            if let Some(end) = rest.find('\'').filter(|&end| end > 0) {
                return Some(rest[..end].to_string());
            }
        }
        from = after;
    }
    None
}

fn plain(name: &str) -> String {
    name.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_uppercase()
}

/// `schema` resolved against `model` to `(chosen, fallbacks)` -- one `.exp`, or a list
/// to try. A file is taken as given; a directory is matched against what the model
/// says it speaks, the longest matching name winning, and where nothing matches the
/// whole directory comes back as fallbacks.
pub fn resolve_schema(model: impl AsRef<Path>, schema: impl AsRef<Path>) -> Result<(Option<PathBuf>, Vec<PathBuf>)> {
    let schema = schema.as_ref();
    if schema.is_file() {
        return Ok((Some(schema.to_path_buf()), Vec::new()));
    }
    if !schema.is_dir() {
        return Err(Error::new(format!("schema {} is neither a file nor a directory", schema.display())));
    }
    let mut available: Vec<PathBuf> = std::fs::read_dir(schema)
        .map_err(|e| Error::new(format!("{}: {e}", schema.display())))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "exp"))
        .collect();
    available.sort();
    if available.is_empty() {
        return Err(Error::new(format!("no .exp schemas in {}", schema.display())));
    }
    let declared = plain(&declared_schema(model)?);
    let stem = |exp: &PathBuf| plain(&exp.file_stem().unwrap_or_default().to_string_lossy());
    let chosen = available
        .iter()
        .filter(|exp| !declared.is_empty() && (declared.starts_with(&stem(exp)) || stem(exp).starts_with(&declared)))
        // The longest name that still matches is the most specific one; the first of
        // equals, as Python's `max` keeps it.
        .fold(None::<&PathBuf>, |best, exp| match best {
            Some(best) if stem(best).len() >= stem(exp).len() => Some(best),
            _ => Some(exp),
        });
    Ok(match chosen {
        Some(chosen) => (Some(chosen.clone()), Vec::new()),
        None => (None, available),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conventions_parse_as_python_parses_them() {
        assert_eq!(Convention::parse("native").unwrap(), 0);
        assert_eq!(Convention::parse(" Unreal ").unwrap(), 1);
        assert_eq!(Convention::parse("y-up").unwrap(), 3);
        assert_eq!(Convention::parse("unreal+file-units").unwrap(), 1 | FILE_UNITS);
        assert!(Convention::parse("z-up").unwrap_err().message().contains("native, unreal"));
        assert!(Convention::parse("unity+metres").is_err());
    }

    #[test]
    fn a_column_major_matrix_reads_as_rows() {
        // A translation by (1, 2, 3): column-major puts it in the last four values.
        let raw = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 2.0, 3.0, 1.0];
        let m = rows(&raw);
        assert_eq!([m[0][3], m[1][3], m[2][3], m[3][3]], [1.0, 2.0, 3.0, 1.0]);
        assert_eq!(m[3][0], 0.0);
    }

    #[test]
    fn segments_pair_each_run_and_skip_points() {
        let positions = [[0.0; 3], [1.0; 3], [2.0; 3], [9.0; 3], [5.0; 3], [6.0; 3]];
        let counts = [3, 1, 2];
        let lines = Polylines { positions: &positions, counts: &counts };
        assert_eq!(lines.segment_indices(), [0, 1, 1, 2, 4, 5]);
        let runs: Vec<usize> = lines.iter().map(<[_]>::len).collect();
        assert_eq!(runs, [3, 1, 2]);
    }

    #[test]
    fn file_schema_reads_the_header_line() {
        assert_eq!(file_schema("ISO-10303-21;\nHEADER;\nFILE_SCHEMA (('IFC2X3'));").as_deref(), Some("IFC2X3"));
        assert_eq!(
            file_schema("file_schema((\n 'AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }'));").as_deref(),
            Some("AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }")
        );
        assert_eq!(file_schema("FILE_SCHEMA_X;"), None);
    }

    #[test]
    fn attribute_text_is_rusts_display() {
        let real = Attribute { name: "t".into(), kind: ValueKind::Real, value: Value::Real(1e-5) };
        assert_eq!(real.text(), "0.00001");
        let big = Attribute { name: "t".into(), kind: ValueKind::Real, value: Value::Real(1e16) };
        assert_eq!(big.text(), "10000000000000000");
        let flag = Attribute { name: "Locked".into(), kind: ValueKind::Boolean, value: Value::Boolean(true) };
        assert_eq!(flag.text(), "true");
        assert!(flag.truthy());
    }
}
