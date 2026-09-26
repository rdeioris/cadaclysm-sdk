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
pub(crate) fn c_path(path: &Path) -> Result<CString> {
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

/// [`groups`] over `f64`, for the `…64` twins.
///
/// # Safety
/// As [`borrowed`], over `count * N` doubles.
unsafe fn groups64<'a, const N: usize>(pointer: *const f64, count: usize) -> Option<&'a [[f64; N]]> {
    (!pointer.is_null()).then(|| unsafe { borrowed(pointer.cast::<[f64; N]>(), count) })
}

/// One RGBA per polyline, copied out; `None` for an edge the file does not style, so "no
/// style" and "styled black" stay distinct. Empty for `{null, 0}` -- nothing styled.
fn colours_of(raw: sys::CadaclysmEdgeColors) -> Vec<Option<[f32; 4]>> {
    unsafe { groups::<4>(raw.rgba, raw.count as usize) }
        .unwrap_or(&[])
        .iter()
        .map(|c| (c[3] >= 0.0).then_some(*c))
        .collect()
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

/// How many coarser levels [`Node::mesh_lod`] offers above the mesh itself (level 0).
pub fn lod_levels() -> Result<u32> {
    Ok(unsafe { (api()?.cadaclysm_lod_levels)() })
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

/// One format [`Node::save_mesh`] writes: its name, the extension its files take (not
/// derivable: `stl-ascii` writes a `.stl`), and a label for a menu (`STL (binary)`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeshFormat {
    pub name: String,
    pub extension: String,
    pub label: String,
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
                label: text((api.cadaclysm_mesh_format_label)(i)),
            }
        })
        .collect())
}

/// One format this build reads: its name and the extensions its files take.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Format {
    pub name: String,
    pub extensions: Vec<String>,
}

/// Every format this build reads, for an open dialog's filter. The library hands the
/// extensions over semicolon-separated; they are split here.
pub fn formats() -> Result<Vec<Format>> {
    let api = api()?;
    let count = unsafe { (api.cadaclysm_format_count)() };
    Ok((0..count)
        .map(|i| unsafe {
            Format {
                name: text((api.cadaclysm_format_name)(i)),
                extensions: text((api.cadaclysm_format_extensions)(i))
                    .split(';')
                    .filter(|e| !e.is_empty())
                    .map(str::to_owned)
                    .collect(),
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

/// Ask the user where to save, through the library's own dialog, with
/// `suggested_name` prefilled. `None` if they cancelled or no dialog was available.
/// Blocks; on macOS, call it from the main thread.
pub fn pick_save(suggested_name: Option<&str>) -> Result<Option<PathBuf>> {
    let api = api()?;
    let name = suggested_name.map(|n| c_string("suggested_name", n)).transpose()?;
    let raw = unsafe { (api.cadaclysm_pick_save)(std::ptr::null(), name.as_ref().map_or(std::ptr::null(), |n| n.as_ptr())) };
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

/// [`Bounds`] in `double`: the same box, unnarrowed -- exact far from the origin,
/// where `f32` is not.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Bounds64 {
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl Bounds64 {
    fn from_raw(raw: sys::CadaclysmBounds64) -> Bounds64 {
        Bounds64 { min: raw.min, max: raw.max }
    }

    /// Whether this is the all-zero box the ABI uses for "nothing here".
    pub fn is_empty(&self) -> bool {
        self.min == [0.0; 3] && self.max == [0.0; 3]
    }

    pub fn size(&self) -> [f64; 3] {
        [0, 1, 2].map(|i| self.max[i] - self.min[i])
    }

    pub fn centre(&self) -> [f64; 3] {
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

/// [`Mesh`] in `double`: the document's own mesh, **lent as it is**, where [`Node::mesh`]
/// hands a `float` copy of it -- the same triangles and indices, `Node::mesh`'s `float`
/// positions being exactly these narrowed. For a caller that uses the mesh as geometry
/// (an exporter, a measurement, a solver) and wants the file's own coordinates, which
/// `float` cannot hold far from the origin. Colours stay `float`.
///
/// **A forget drops it.** [`Scene::forget_meshes`] frees the document's mesh these
/// slices borrow, but takes `&mut Scene`, so the borrow checker rules out holding a
/// `Mesh64` across a forget: nothing here needs a runtime check.
#[derive(Clone, Copy, Debug)]
pub struct Mesh64<'s> {
    pub positions: &'s [[f64; 3]],
    pub normals: Option<&'s [[f64; 3]]>,
    pub uvs: Option<&'s [[f64; 2]]>,
    pub colors: Option<&'s [[f32; 4]]>,
    /// Three to a triangle, into `positions`.
    pub indices: &'s [u32],
}

impl<'s> Mesh64<'s> {
    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn index_count(&self) -> usize {
        self.indices.len()
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }

    pub fn is_empty(&self) -> bool {
        self.indices.is_empty() || self.positions.is_empty()
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

/// A node's edges, curves or isocurves as cubic Bézier curves -- exact where the file's
/// curves were, where [`Polylines`] are their chords -- borrowed from the scene.
/// `points` holds four control points a curve; `weights` a weight per control point,
/// all ones for a polynomial curve and the weights that make a circular arc exact for
/// a rational one.
#[derive(Clone, Copy, Debug)]
pub struct Beziers<'s> {
    pub points: &'s [[f32; 3]],
    pub weights: &'s [f32],
}

/// A [`Beziers`] in memory of the program's own.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BeziersData {
    pub points: Vec<[f32; 3]>,
    pub weights: Vec<f32>,
}

impl<'s> Beziers<'s> {
    fn from_raw(raw: sys::CadaclysmBeziers) -> Beziers<'s> {
        let n = raw.count as usize;
        unsafe {
            Beziers {
                points: groups::<3>(raw.points, n * 4).unwrap_or(&[]),
                weights: borrowed(raw.weights, n * 4),
            }
        }
    }

    /// How many curves.
    pub fn count(&self) -> usize {
        self.weights.len() / 4
    }

    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    /// One curve's four control points at a time.
    pub fn iter(&self) -> impl Iterator<Item = &'s [[f32; 3]]> + 's {
        self.points.chunks_exact(4)
    }

    pub fn copy(&self) -> BeziersData {
        BeziersData { points: self.points.to_vec(), weights: self.weights.to_vec() }
    }
}

/// [`Beziers`] in `double`: the same segments, unnarrowed -- the `float` ones are
/// these narrowed. Borrowed from the scene until it is closed.
#[derive(Clone, Copy, Debug)]
pub struct Beziers64<'s> {
    pub points: &'s [[f64; 3]],
    pub weights: &'s [f64],
}

impl<'s> Beziers64<'s> {
    fn from_raw(raw: sys::CadaclysmBeziers64) -> Beziers64<'s> {
        let n = raw.count as usize;
        unsafe {
            Beziers64 {
                points: groups64::<3>(raw.points, n * 4).unwrap_or(&[]),
                weights: borrowed(raw.weights, n * 4),
            }
        }
    }

    /// How many curves.
    pub fn count(&self) -> usize {
        self.weights.len() / 4
    }

    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    /// One curve's four control points at a time.
    pub fn iter(&self) -> impl Iterator<Item = &'s [[f64; 3]]> + 's {
        self.points.chunks_exact(4)
    }
}

/// What a node turned out to be for a physics engine: a box, sphere, capsule or
/// cylinder where one fits within `error`, else a convex hull. `frame` (column-major)
/// and `half_extent` are always the true oriented box. Plain data, copied out.
#[derive(Clone, Debug, PartialEq)]
pub struct Collision {
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

impl Collision {
    /// `none`, `box`, `sphere`, `capsule`, `cylinder` or `hull`.
    pub fn shape_name(&self) -> &'static str {
        ["none", "box", "sphere", "capsule", "cylinder", "hull"].get(self.shape as usize).copied().unwrap_or("?")
    }
}

/// A node's convex hull for a physics engine, as triangles, copied out of the scene:
/// the library frees its own copy when the node is asked for a different `hull_budget`,
/// so a borrow would not be sound.
#[derive(Clone, Debug, Default)]
pub struct CollisionHull {
    pub positions: Vec<[f32; 3]>,
    pub indices: Vec<u32>,
}

impl CollisionHull {
    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn index_count(&self) -> usize {
        self.indices.len()
    }

    pub fn is_empty(&self) -> bool {
        self.positions.is_empty()
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

// ---- meshlets ---------------------------------------------------------------------

/// One meshlet, copied out: the vectors are yours.
#[derive(Clone, Debug, PartialEq)]
pub struct Meshlet {
    pub index: u32,
    /// 0 for a leaf over the mesh itself, higher for a simplified level above it.
    pub level: u32,
    pub group: u32,
    /// How far this meshlet's level moved the surface; zero at level 0.
    pub error: f32,
    pub positions: Vec<[f32; 3]>,
    /// Zeros where the mesh had none.
    pub normals: Vec<[f32; 3]>,
    /// Three a triangle, into this meshlet's own `positions`.
    pub indices: Vec<u32>,
    /// The finer meshlets below this one, for a levelled build.
    pub children: Vec<u32>,
}

impl Meshlet {
    pub fn vertex_count(&self) -> usize {
        self.positions.len()
    }

    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }
}

/// A mesh split into meshlets, optionally with coarser levels above them, for a
/// mesh-shader or meshlet-based renderer. Built from any mesh -- a [`Node::mesh`] or
/// slices of your own -- and freed when dropped.
pub struct Meshlets {
    pointer: NonNull<sys::CadaclysmMeshlets>,
    api: &'static Api,
}

// The library builds and reads meshlets with no thread affinity; the handle is owned.
unsafe impl Send for Meshlets {}

impl Meshlets {
    /// Split `positions`, `normals` (or `None`) and `indices` (three a triangle) into
    /// meshlets of at most `max_triangles` and `max_vertices` each -- the consumer's own
    /// limits, with no default: Nanite takes 128/256, a mesh-shader pipeline 124/64.
    /// `levels` above 0 groups and simplifies each level into the next until one meshlet
    /// is left; [`Meshlets::level`] and [`Meshlet::children`] say which is which.
    pub fn build(
        positions: &[[f32; 3]],
        normals: Option<&[[f32; 3]]>,
        indices: &[u32],
        max_triangles: u32,
        max_vertices: u32,
        levels: i32,
    ) -> Result<Meshlets> {
        let api = api()?;
        if max_triangles == 0 || max_vertices == 0 {
            return Err(Error::new("meshlets: max_triangles and max_vertices are required"));
        }
        if indices.len() % 3 != 0 {
            return Err(Error::new("meshlets: indices must hold three a triangle"));
        }
        if let Some(n) = normals {
            if n.len() != positions.len() {
                return Err(Error::new("meshlets: normals must hold one per vertex"));
            }
        }
        let pointer = unsafe {
            (api.cadaclysm_meshlets_build)(
                positions.as_ptr().cast(),
                normals.map_or(std::ptr::null(), |n| n.as_ptr().cast()),
                positions.len(),
                indices.as_ptr(),
                indices.len(),
                max_triangles,
                max_vertices,
                levels,
            )
        };
        let pointer = NonNull::new(pointer).ok_or_else(|| {
            let reason = last_error(api);
            Error::new(if reason.is_empty() { "meshlets: build failed".to_string() } else { reason })
        })?;
        Ok(Meshlets { pointer, api })
    }

    fn raw(&self) -> *const sys::CadaclysmMeshlets {
        self.pointer.as_ptr()
    }

    /// How many meshlets, every level counted.
    pub fn count(&self) -> u32 {
        unsafe { (self.api.cadaclysm_meshlets_count)(self.raw()) }
    }

    pub fn triangle_count(&self, i: u32) -> u32 {
        unsafe { (self.api.cadaclysm_meshlet_triangle_count)(self.raw(), i) }
    }

    pub fn vertex_count(&self, i: u32) -> u32 {
        unsafe { (self.api.cadaclysm_meshlet_vertex_count)(self.raw(), i) }
    }

    /// 0 for a leaf over the mesh itself, higher for a simplified level above it.
    pub fn level(&self, i: u32) -> u32 {
        unsafe { (self.api.cadaclysm_meshlet_level)(self.raw(), i) }
    }

    pub fn group(&self, i: u32) -> u32 {
        unsafe { (self.api.cadaclysm_meshlet_group)(self.raw(), i) }
    }

    /// How far this meshlet's level moved the surface; zero at level 0.
    pub fn error(&self, i: u32) -> f32 {
        unsafe { (self.api.cadaclysm_meshlet_error)(self.raw(), i) }
    }

    pub fn child_count(&self, i: u32) -> u32 {
        unsafe { (self.api.cadaclysm_meshlet_child_count)(self.raw(), i) }
    }

    /// One meshlet's arrays and numbers, copied out.
    pub fn meshlet(&self, i: u32) -> Meshlet {
        let vertices = self.vertex_count(i) as usize;
        let triangles = self.triangle_count(i) as usize;
        let children = self.child_count(i) as usize;
        let mut positions = vec![[0.0f32; 3]; vertices];
        let mut normals = vec![[0.0f32; 3]; vertices];
        let mut indices = vec![0u32; triangles * 3];
        let mut kids = vec![0u32; children];
        unsafe {
            (self.api.cadaclysm_meshlet_positions)(self.raw(), i, positions.as_mut_ptr().cast());
            (self.api.cadaclysm_meshlet_normals)(self.raw(), i, normals.as_mut_ptr().cast());
            (self.api.cadaclysm_meshlet_indices)(self.raw(), i, indices.as_mut_ptr());
            (self.api.cadaclysm_meshlet_children)(self.raw(), i, kids.as_mut_ptr());
        }
        Meshlet {
            index: i,
            level: self.level(i),
            group: self.group(i),
            error: self.error(i),
            positions,
            normals,
            indices,
            children: kids,
        }
    }
}

impl Drop for Meshlets {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_meshlets_free)(self.pointer.as_ptr()) }
    }
}

impl fmt::Debug for Meshlets {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Meshlets(count={})", self.count())
    }
}

// ---- the FEM surface mesh ---------------------------------------------------------

/// One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
/// breaks. The numbers are copied out; `nodes` and `runs` are borrowed from the
/// [`FemMesh`], as its own arrays are.
///
/// `nodes` are the mesh's node indices in order along the edge, its end vertices
/// included; a closed edge repeats no node. **`runs` says where the chain breaks**: read
/// `nodes[runs[i]..runs[i + 1]]` (the last run to the end) as one polyline and join
/// nothing across a boundary -- the two ends either side of one are two points of the
/// edge with no mesh edge between them, a crack along the edge or a stretch of it the
/// mesher sampled on one face only. [`FemEdge::chains`] does that walk; `[0]` is the
/// ordinary answer, and reading `nodes` as one polyline without looking here jumps the
/// gap silently.
///
/// `faces` is `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of each
/// [`NONE`] where there is none -- an open body's rim, or both ends at one vertex (a
/// closed edge, a circle's rim, a full-turn seam). **`0` is a real face and a real
/// vertex, not a sentinel.** Which end comes first is the first trim's direction and
/// means nothing else: the pair bounds the edge, it does not orient it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FemEdge<'m> {
    /// The **body's own** edge id -- not this mesh's edge index, and on a read body
    /// rarely equal to it. [`FemMesh::edges`] is a densely renumbered subset of the
    /// body's edges, ascending by id, with every edge collapsed to a point left out, so
    /// edge 0 of a STEP body's mesh routinely reports an id in the hundreds. Everything
    /// else here that names an edge means the *index* -- a [`FemMesh::node_kind`] of 1
    /// read through [`FemMesh::node_entity`], the third number of a census row, and the
    /// `edge_<i>` physical group of [`FemMesh::msh_text`] -- and this is the one way back
    /// from any of them to the topology the file wrote.
    pub id: u32,
    pub nodes: &'m [u32],
    /// Where each connected run of `nodes` begins; `[0]` for one chain along the edge.
    pub runs: &'m [u32],
    /// `(face_a, face_b)`, the second [`NONE`] on an open body's rim.
    pub faces: (u32, u32),
    /// `(end_a, end_b)`, the second [`NONE`] where both ends are one vertex.
    pub ends: (u32, u32),
    /// The nodes make one loop. Never true where there is more than one run.
    pub closed: bool,
    /// Bounded twice by one face: a closed surface's seam, not a real boundary. Both
    /// `faces` are then that same face.
    pub seam: bool,
}

impl<'m> FemEdge<'m> {
    /// # Safety
    /// `raw`'s `nodes` and `runs` must be null or point at their counts' worth of `u32`s
    /// living for `'m` -- which they do for as long as the [`FemMesh`] they came from.
    unsafe fn from_raw(raw: &sys::CadaclysmFemEdge) -> FemEdge<'m> {
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
    /// `runs` is for. One item is the ordinary answer.
    pub fn chains(&self) -> impl Iterator<Item = &'m [u32]> + '_ {
        let nodes = self.nodes;
        (0..self.runs.len()).map(move |i| {
            let start = (self.runs[i] as usize).min(nodes.len());
            let end = self.runs.get(i + 1).map_or(nodes.len(), |&r| (r as usize).min(nodes.len()));
            &nodes[start..start.max(end)]
        })
    }
}

/// One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
/// topology says it is, if that is known. Plain data, all of it copied out.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FemVertex {
    /// The mesh node at this vertex, or [`NONE`] where the mesh has none there.
    ///
    /// **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex
    /// wherever two trims meet, and a pole's polyline runs give a sphere 48 of them where
    /// the mesh has 2 points, so a caller walking these skips the sentinel rather than
    /// treating it as a gap.
    pub node: u32,
    /// Where the vertex is, in the same space and under the same placement as
    /// [`FemMesh::nodes`] -- the file's own vertex rather than a mesh node, so the two can
    /// differ by the reader's rounding. **Meaningless unless `has_position`**: it is
    /// zeroed then, a point no geometry has and one a solver would read as a node at the
    /// origin.
    pub point: [f64; 3],
    /// `point` was read and placed. False where every trim meeting at this vertex is a
    /// curve with no geometry to read an end off -- reported as this flag rather than as a
    /// plausible-looking `(0, 0, 0)`.
    pub has_position: bool,
}

impl FemVertex {
    fn from_raw(raw: &sys::CadaclysmFemVertex) -> FemVertex {
        FemVertex { node: raw.node, point: raw.point, has_position: raw.has_position }
    }
}

/// One body meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack
/// reported rather than closed. What [`Node::fem_mesh`] returns.
///
/// **An owned handle, and it owns everything it lends.** Freed when dropped, or by
/// [`FemMesh::free`]; it borrows nothing from the [`Scene`] it was built through, so it
/// needs no lifetime of its own and outlives the scene's close -- which is why it is the
/// one thing in this crate a `Scene` does not hold.
///
/// Its five flat arrays are **slices of the library's own memory** borrowed from `&self`,
/// as [`Node::mesh`]'s are borrowed from the scene: a solver mesh is megabytes, and
/// copying it to hand it over would cost that twice. Here that costs nothing to get
/// right. Every other wrapper needs a run-time guard against a view read after the
/// handle is freed -- and none of them can guard a view *already in hand*, which is
/// measured to read freed memory. This one cannot compile:
///
/// ```compile_fail,E0505
/// # fn main() -> cadaclysm_sdk::Result<()> {
/// let scene = cadaclysm_sdk::open("part.stp")?;
/// let mesh = scene.roots()[0].fem_mesh(0.01, 0.0, None)?;
/// let nodes = mesh.nodes();
/// mesh.free(); // error: `mesh` is still borrowed by `nodes`
/// let _ = nodes.len();
/// # Ok(())
/// # }
/// ```
///
/// **That block is documentation, not an assertion.** `compile_fail` asks only that the
/// snippet fail to compile and rustdoc never checks *what* failed, so a typo in it would
/// pass too: it pins the claim no more firmly than this sentence does. What makes the claim
/// true is [`FemMesh::free`] taking the mesh by value, and the block is here so a reader
/// sees the shape of the refusal.
///
/// `.to_vec()` on anything that must outlive the handle.
pub struct FemMesh {
    pointer: NonNull<sys::CadaclysmFemMesh>,
    api: &'static Api,
    /// Read once, when the handle is made: every pointer in it is built with the handle
    /// and never moves (nothing in this ABI is built lazily), so asking again per
    /// accessor would be one C call for the same answer.
    view: sys::CadaclysmFemMeshView,
}

// The handle is owned outright and every accessor of it takes a `const` pointer, so it
// may move to another thread. Not `Sync`: the `.msh` text is a slot on the handle, and
// two threads asking for it at once free each other's text -- the ABI says so.
unsafe impl Send for FemMesh {}

impl FemMesh {
    /// The handle a `*_fem_mesh` call returned, with its view read once -- or the
    /// library's own reason for the null.
    fn wrap(api: &'static Api, pointer: *mut sys::CadaclysmFemMesh) -> Result<FemMesh> {
        let pointer = NonNull::new(pointer).ok_or_else(|| {
            let reason = last_error(api);
            Error::new(if reason.is_empty() { "fem_mesh".to_string() } else { reason })
        })?;
        let mut view = std::mem::MaybeUninit::<sys::CadaclysmFemMeshView>::uninit();
        if !unsafe { (api.cadaclysm_fem_mesh_view)(pointer.as_ptr(), view.as_mut_ptr()) } {
            let reason = last_error(api);
            unsafe { (api.cadaclysm_fem_mesh_free)(pointer.as_ptr()) };
            return Err(Error::new(if reason.is_empty() { "fem mesh view".to_string() } else { reason }));
        }
        // SAFETY: the call returned true, so it wrote the whole struct.
        Ok(FemMesh { pointer, api, view: unsafe { view.assume_init() } })
    }

    fn raw(&self) -> *const sys::CadaclysmFemMesh {
        self.pointer.as_ptr()
    }

    // -- the flat arrays, borrowed from the handle

    /// Every node's position, placed, in the space [`Node::fem_mesh`] and
    /// [`FemMesh::from_mesh`] describe. Every node is used by at least one triangle.
    pub fn nodes(&self) -> &[[f64; 3]] {
        // SAFETY: the pointers were built with the handle and live until it is freed,
        // which `&self` rules out for the life of the slice.
        unsafe { groups64::<3>(self.view.nodes, self.view.node_count as usize).unwrap_or(&[]) }
    }

    /// Three node indices a triangle, wound outward -- a mirroring placement is wound
    /// back. Grouped, not flat, unlike [`Mesh::indices`]: the ABI's array *is*
    /// `[u32; 3]` a triangle, and a solver reads triangles rather than an index buffer.
    pub fn triangles(&self) -> &[[u32; 3]] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.triangles.cast::<[u32; 3]>(), self.view.triangle_count as usize) }
    }

    /// Which B-rep face each triangle lies on, one per triangle, into the body's
    /// [`FemMesh::face_count`] faces.
    pub fn triangle_face(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.triangle_face, self.view.triangle_count as usize) }
    }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    /// classification rule. [`FemMesh::node_entity`] says which entity of that kind.
    pub fn node_kind(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.node_kind, self.view.node_count as usize) }
    }

    /// Which vertex, edge or face each node lies on, read by the matching
    /// [`FemMesh::node_kind`]: an index into [`FemMesh::vertices`], into
    /// [`FemMesh::edges`], or into the body's faces.
    pub fn node_entity(&self) -> &[u32] {
        // SAFETY: as `nodes`.
        unsafe { borrowed(self.view.node_entity, self.view.node_count as usize) }
    }

    // -- the topology

    /// The body's faces; [`FemMesh::triangle_face`] and a [`FemMesh::node_kind`] of `2`
    /// index them. **The same faces [`Node::surfaces`] hands over**, in the same order, so
    /// a caller reads a triangle's surface and its trims from there.
    pub fn face_count(&self) -> u32 {
        self.view.face_count
    }

    /// One [`FemEdge`] per B-rep edge, in the order a [`FemMesh::node_kind`] of `1`
    /// indexes them. Empty for a [`FemMesh::from_mesh`] body, which has no B-rep edges at
    /// all.
    ///
    /// **This list's own numbering, not the body's**: each [`FemEdge::id`] carries the
    /// body's own edge id.
    pub fn edges(&self) -> Result<Vec<FemEdge<'_>>> {
        (0..self.view.edge_count)
            .map(|i| {
                let mut raw = std::mem::MaybeUninit::<sys::CadaclysmFemEdge>::uninit();
                if !unsafe { (self.api.cadaclysm_fem_mesh_edge)(self.raw(), i, raw.as_mut_ptr()) } {
                    let reason = last_error(self.api);
                    return Err(Error::new(if reason.is_empty() { format!("fem mesh edge {i}") } else { reason }));
                }
                // SAFETY: the call returned true, so it wrote the whole struct; its two
                // pointers belong to the handle, which `&self` holds for `'_`.
                Ok(unsafe { FemEdge::from_raw(&raw.assume_init()) })
            })
            .collect()
    }

    /// One [`FemVertex`] per B-rep vertex, in the order a [`FemMesh::node_kind`] of `0`
    /// indexes them. Empty for a [`FemMesh::from_mesh`] body.
    pub fn vertices(&self) -> Result<Vec<FemVertex>> {
        (0..self.view.vertex_count)
            .map(|i| {
                let mut raw = std::mem::MaybeUninit::<sys::CadaclysmFemVertex>::uninit();
                if !unsafe { (self.api.cadaclysm_fem_mesh_vertex)(self.raw(), i, raw.as_mut_ptr()) } {
                    let reason = last_error(self.api);
                    return Err(Error::new(if reason.is_empty() { format!("fem mesh vertex {i}") } else { reason }));
                }
                // SAFETY: the call returned true, so it wrote the whole struct.
                Ok(FemVertex::from_raw(&unsafe { raw.assume_init() }))
            })
            .collect()
    }

    // -- the crack census

    /// Every crack, as `(a, b, brep_edge)`: a directed mesh edge `(a, b)` with no
    /// `(b, a)`, and the B-rep edge both nodes lie on or [`NONE`] where they share none.
    ///
    /// **Empty unless the body's topology is closed -- for a B-rep body**, whose mesh is
    /// otherwise not asked about at all: such a body reports [`FemMesh::watertight`]
    /// false with this and [`FemMesh::folded_edges`] both empty, and *that trio together*
    /// says "not asked", not "nothing found".
    ///
    /// **A [`FemMesh::from_mesh`] body is the other case, and the opposite one.** A bare
    /// mesh carries no topology to say whether it ought to close, so its census always
    /// runs over the welded triangles, and an empty one there really does mean "nothing
    /// found".
    pub fn open_edges(&self) -> Result<Vec<(u32, u32, u32)>> {
        self.census(self.api.cadaclysm_fem_mesh_open_edge, self.view.open_edge_count, "open edge")
    }

    /// Every fold, as [`FemMesh::open_edges`] reports a crack: a directed mesh edge used
    /// by more than one triangle.
    ///
    /// **A body can be folded without being open** -- a solid no thicker than a line
    /// leaves no hole for an open edge to find -- and the closure census's own known-bad
    /// bodies are folds rather than open cracks. A caller that checks
    /// [`FemMesh::open_edges`] alone calls such a body sound. Empty under the same rule.
    pub fn folded_edges(&self) -> Result<Vec<(u32, u32, u32)>> {
        self.census(self.api.cadaclysm_fem_mesh_folded_edge, self.view.folded_edge_count, "folded edge")
    }

    /// One flattened census, row by row: the shape [`FemMesh::open_edges`] and
    /// [`FemMesh::folded_edges`] share, so the two cannot drift.
    fn census(
        &self,
        call: unsafe extern "C" fn(*const sys::CadaclysmFemMesh, u32, *mut u32, *mut u32, *mut u32) -> bool,
        count: u32,
        what: &str,
    ) -> Result<Vec<(u32, u32, u32)>> {
        (0..count)
            .map(|i| {
                let (mut a, mut b, mut edge) = (0u32, 0u32, 0u32);
                if !unsafe { call(self.raw(), i, &mut a, &mut b, &mut edge) } {
                    let reason = last_error(self.api);
                    return Err(Error::new(if reason.is_empty() { format!("fem mesh {what} {i}") } else { reason }));
                }
                Ok((a, b, edge))
            })
            .collect()
    }

    // -- the summary

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none
    /// used twice -- and, for a B-rep body, so does the topology behind it. **False for
    /// every B-rep body whose topology is not closed**, whose mesh is then not asked
    /// about; read [`FemMesh::open_edges`] for what an empty census beside a false here
    /// does and does not mean.
    ///
    /// A [`FemMesh::from_mesh`] body has no topology to ask of, so this says only that its
    /// triangles close: a closed render mesh reports true with nothing exact behind it.
    pub fn watertight(&self) -> bool {
        self.view.watertight
    }

    /// This came from the scene's own mesh rather than from a brep: one face, every node
    /// on face `0`, no edges and no vertices.
    ///
    /// **It is also which space the mesh is in.** A B-rep body's FEM mesh is in the file's
    /// own units and axes, whatever [`Convention`] the scene was opened with, because it
    /// is taken off the brep -- and a brep is in the file's own space for the reason
    /// [`Brep`] gives. A node with no brep falls back to the scene's mesh, which **is**
    /// converted, so that one comes back in the scene's convention, wound
    /// counter-clockwise about the outward normal even where the convention winds the
    /// other way. Under a non-native convention those are two different spaces.
    ///
    /// **And it is which contract the census is reporting under**: read
    /// [`FemMesh::open_edges`].
    pub fn from_mesh(&self) -> bool {
        self.view.from_mesh
    }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a
    /// body that meshed to no triangles is a refusal, not a mesh.
    pub fn min_angle(&self) -> f64 {
        self.view.min_angle
    }

    /// The triangle with that angle, as an index into [`FemMesh::triangles`].
    pub fn worst_triangle(&self) -> u32 {
        self.view.worst_triangle
    }

    /// The longest triangle edge, placed. **The figure to check against
    /// [`Node::fem_mesh`]'s `max_size`, and the only one that says what the mesh actually
    /// is**: `max_size` bounds the boundary segments and merely *targets* the interior --
    /// measured at 1.03x `max_size` on a face whose parameters run unevenly -- and one
    /// small enough beside the body to reach the mesher's own piece and station ceilings
    /// is not honoured at all.
    pub fn longest_edge(&self) -> f64 {
        self.view.longest_edge
    }

    // -- out

    /// The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
    /// a volume where the body closes, and a physical group naming each.
    ///
    /// **On this side of the ABI the library's text is borrowed** -- a slot on this
    /// handle, replaced by the next call on it and gone when the mesh is freed. It is
    /// copied into a `String` here, so what comes back is the caller's own and outlives
    /// the handle; nothing has to be freed. The kernel library's
    /// [`blacksmith::FemMesh::msh_text`] is the other way round: an owned string, released
    /// by that wrapper with `cadaclysm_blacksmith_string_free`. A reader porting one
    /// side's reasoning onto the other leaks or double-frees.
    ///
    /// **No unlicensed notice is printed here.** [`Node::fem_mesh`] gave it once when the
    /// mesh was built, and this ABI deliberately does not repeat it on either `.msh` call
    /// -- where the kernel library notices on both of its writers and *not* on its
    /// builder. Each matches its own siblings.
    ///
    /// An error for a mesh the writer refuses, naming the field it cannot honour.
    pub fn msh_text(&self) -> Result<String> {
        let raw = unsafe { (self.api.cadaclysm_fem_mesh_msh_text)(self.raw()) };
        if raw.is_null() {
            let reason = last_error(self.api);
            return Err(Error::new(if reason.is_empty() { "msh text".to_string() } else { reason }));
        }
        // Copied, not freed: the pointer is the handle's own slot.
        Ok(unsafe { text(raw) })
    }

    /// [`FemMesh::msh_text`] written to `path` by the library itself: the same bytes from
    /// the same writer, straight to the file rather than through the borrowed slot, so a
    /// text asked of this handle on another thread cannot be freed under the write.
    ///
    /// An error for a mesh the writer refuses or a file it cannot write, naming the path.
    /// No notice here either; see [`FemMesh::msh_text`].
    pub fn save_msh(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = c_path(path.as_ref())?;
        if !unsafe { (self.api.cadaclysm_fem_mesh_save_msh)(self.raw(), path.as_ptr()) } {
            let reason = last_error(self.api);
            return Err(Error::new(if reason.is_empty() { "save_msh".to_string() } else { reason }));
        }
        Ok(())
    }

    /// Give the mesh back now rather than at the end of scope, as [`Brep::release`] and
    /// [`blacksmith::Solid::close`] do.
    ///
    /// **It takes the mesh by value, so no view can survive it and it cannot run twice.**
    /// Every other wrapper needs "idempotent" and a freed guard because its `free` is a
    /// method on a handle a caller still holds; here the compiler takes the handle away.
    pub fn free(self) {}
}

impl Drop for FemMesh {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_fem_mesh_free)(self.pointer.as_ptr()) }
    }
}

impl fmt::Debug for FemMesh {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "FemMesh(nodes={}, triangles={}, watertight={}, from_mesh={})",
            self.view.node_count, self.view.triangle_count, self.view.watertight, self.view.from_mesh
        )
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

// ---- links and joints ---------------------------------------------------------------

/// A rigid body of the file's mechanism: the nodes that move together when a joint
/// moves it. From [`Scene::links`]; borrows from the scene like [`Node`].
#[derive(Clone, Copy)]
pub struct Link<'s> {
    scene: &'s Scene,
    index: u32,
}

// Identity is the pair, so the same link from two lookups is equal and can key a map.
impl PartialEq for Link<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index && std::ptr::eq(self.scene, other.scene)
    }
}

impl Eq for Link<'_> {}

impl Hash for Link<'_> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.scene as *const Scene).hash(state);
        self.index.hash(state);
    }
}

impl fmt::Debug for Link<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<Link {} {}>", self.index, self.name())
    }
}

impl<'s> Link<'s> {
    pub fn scene(&self) -> &'s Scene {
        self.scene
    }

    pub fn index(&self) -> u32 {
        self.index
    }

    /// The link's name as the file gives it.
    pub fn name(&self) -> String {
        unsafe { text((self.scene.api.cadaclysm_link_name)(self.scene.raw(), self.index)) }
    }

    /// The topmost node of each subtree this link moves, in node order: moving these
    /// moves everything under them.
    pub fn nodes(&self) -> Vec<Node<'s>> {
        let api = self.scene.api;
        let count = unsafe { (api.cadaclysm_link_node_count)(self.scene.raw(), self.index) };
        (0..count)
            .map(|i| Node { scene: self.scene, index: unsafe { (api.cadaclysm_link_node)(self.scene.raw(), self.index, i) } })
            .collect()
    }
}

/// A connection between two links of the file's mechanism. Topology only: how it
/// moves is not read yet. From [`Scene::joints`].
#[derive(Clone, Copy)]
pub struct Joint<'s> {
    scene: &'s Scene,
    index: u32,
}

impl PartialEq for Joint<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index && std::ptr::eq(self.scene, other.scene)
    }
}

impl Eq for Joint<'_> {}

impl Hash for Joint<'_> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.scene as *const Scene).hash(state);
        self.index.hash(state);
    }
}

impl fmt::Debug for Joint<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<Joint {} {}>", self.index, self.name())
    }
}

impl<'s> Joint<'s> {
    pub fn scene(&self) -> &'s Scene {
        self.scene
    }

    pub fn index(&self) -> u32 {
        self.index
    }

    /// The joint's name as the file gives it.
    pub fn name(&self) -> String {
        unsafe { text((self.scene.api.cadaclysm_joint_name)(self.scene.raw(), self.index)) }
    }

    /// The link this joint starts at, in the file's order -- not a parent: a
    /// mechanism may be a network with loops.
    pub fn start(&self) -> Link<'s> {
        let index = unsafe { (self.scene.api.cadaclysm_joint_start)(self.scene.raw(), self.index) };
        Link { scene: self.scene, index }
    }

    /// The link this joint ends at, in the file's order.
    pub fn end(&self) -> Link<'s> {
        let index = unsafe { (self.scene.api.cadaclysm_joint_end)(self.scene.raw(), self.index) };
        Link { scene: self.scene, index }
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

    /// [`Node::bounds`] in `double`: the same box, unnarrowed -- exact far from the
    /// origin, where `bounds`'s widened `f32` positions are not.
    pub fn bounds64(&self) -> Bounds64 {
        Bounds64::from_raw(self.call(self.scene.api.cadaclysm_node_bounds64))
    }

    fn mesh_of(&self, raw: sys::CadaclysmMesh) -> Mesh<'s> {
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

    /// Its triangles, in their own frame, built now if they have not been. Where the
    /// node instances another, these are the instanced node's triangles -- two
    /// occurrences of one shape hand back the *same* slices.
    pub fn mesh(&self) -> Mesh<'s> {
        self.mesh_of(self.call(self.scene.api.cadaclysm_node_mesh))
    }

    /// [`Node::mesh`] in `double`: the document's own mesh, **lent as it is** rather
    /// than narrowed -- see [`Mesh64`]. `None` for a node with no triangles.
    pub fn mesh64(&self) -> Option<Mesh64<'s>> {
        let raw = self.call(self.scene.api.cadaclysm_node_mesh64);
        if raw.positions.is_null() || raw.index_count == 0 {
            return None;
        }
        let n = raw.vertex_count as usize;
        // SAFETY: as `mesh_of` -- the scene keeps every mesh it built until it closes
        // or `forget_meshes` runs, and `'s` borrows the scene either way.
        unsafe {
            Some(Mesh64 {
                positions: groups64::<3>(raw.positions, n).unwrap_or(&[]),
                normals: groups64::<3>(raw.normals, n),
                uvs: groups64::<2>(raw.uvs, n),
                colors: groups::<4>(raw.colors, n),
                indices: borrowed(raw.indices, raw.index_count as usize),
            })
        }
    }

    /// This node's body meshed for a solver, as a [`FemMesh`]: nodes welded by bits -- two
    /// mesh points are one node only where their coordinates are the same doubles, so no
    /// tolerance ever merges two distinct points and a crack stays a crack -- triangles
    /// wound outward, and every node tagged with the lowest-dimension B-rep entity it lies
    /// on.
    ///
    /// `tolerance` is the chordal tolerance in model units, finite and above zero, and
    /// **it alone governs how closely the mesh follows the geometry**. `max_size` is a size
    /// ceiling, finite and zero or more, `0` being no ceiling (curvature alone): **it
    /// bounds the boundary and targets the interior**, which is not a longest-element-edge
    /// guarantee -- it adds boundary nodes without refining boundary geometry, and
    /// [`FemMesh::longest_edge`] is what the mesh actually came to.
    ///
    /// **Neither is checked here.** On the mesh-only path below, the library reads no
    /// options at all: a `tolerance` of 0, -1 or NaN and a `max_size` of -1 or NaN all
    /// come back as a mesh, while the B-rep path refuses each in its own words. A wrapper
    /// that validated either field would pass every test written against the B-rep path
    /// and be wrong; both go through as given. `0.01` and `0.0` are `FemOptions::default()`
    /// -- the library's struct is still filled by `cadaclysm_fem_options_init` first, so a
    /// field added to it later defaults without this code being touched.
    ///
    /// `placement` is **sixteen** numbers, column-major, as [`Node::bounds_placed`] takes
    /// them (`None` for the identity), applied in `f64` throughout. The kernel library's
    /// [`blacksmith::Solid::fem_mesh`] takes **twelve** instead -- a [`blacksmith::Frame`]:
    /// origin, x, y, z -- so a caller moving between the two reformats the placement. Both
    /// are sized types here, so that confusion does not compile.
    ///
    /// **The space is the body's, not the scene's, for a B-rep -- and the scene's for a
    /// mesh**, which [`FemMesh::from_mesh`] is the flag for; read it there, because under a
    /// non-native convention the two are different spaces. Meshed in the part's own frame,
    /// following the hop from an instance to the shape it draws that [`Node::mesh`]
    /// follows, so a node instanced six times meshes once.
    ///
    /// **A cracked body is not a failure**: it comes back with [`FemMesh::watertight`]
    /// false and its cracks in [`FemMesh::open_edges`] / [`FemMesh::folded_edges`], and
    /// nothing is welded shut to make it look sound. An error for a tolerance or size the
    /// mesher refuses, a placement that is not finite and invertible, a node with neither a
    /// brep nor a mesh (an assembly, a storey, a layer, an empty definition, a curve), and
    /// a body that meshes to no triangles at all.
    ///
    /// Prints the unlicensed notice once, here, and not again on either of [`FemMesh`]'s
    /// `.msh` calls.
    pub fn fem_mesh(&self, tolerance: f64, max_size: f64, placement: Option<&[f64; 16]>) -> Result<FemMesh> {
        let api = self.scene.api;
        let mut options = std::mem::MaybeUninit::<sys::CadaclysmFemOptions>::uninit();
        unsafe { (api.cadaclysm_fem_options_init)(options.as_mut_ptr()) };
        // SAFETY: `init` writes the library's whole `CadaclysmFemOptions`, which
        // `tests/bindings.rs` pins to this crate's declaration field for field.
        let mut options = unsafe { options.assume_init() };
        // `size` is then this crate's own, which is what the growth rule asks of a caller.
        options.size = std::mem::size_of::<sys::CadaclysmFemOptions>();
        options.tolerance = tolerance;
        options.max_size = max_size;
        let matrix = placement.map_or(std::ptr::null(), |m| m.as_ptr());
        FemMesh::wrap(api, unsafe { (api.cadaclysm_node_fem_mesh)(self.scene.raw(), self.index, matrix, &options) })
    }

    /// Its triangles at a coarser level of detail: 0 is [`Node::mesh`] itself, 1 up to
    /// [`lod_levels`] each about a quarter of the triangles of the one before, and past
    /// that empty. Every level shares the level-0 vertices -- the same `positions`, only
    /// `indices` differ -- so upload the vertices once and switch level by drawing a
    /// different index range.
    pub fn mesh_lod(&self, level: u32) -> Mesh<'s> {
        self.mesh_of(unsafe { (self.scene.api.cadaclysm_node_mesh_lod)(self.scene.raw(), self.index, level) })
    }

    /// How far [`Node::mesh_lod`] at this level moved the surface, in the scene's units
    /// -- what to pick a level by. Zero at level 0.
    pub fn lod_error(&self, level: u32) -> f32 {
        unsafe { (self.scene.api.cadaclysm_node_lod_error)(self.scene.raw(), self.index, level) }
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

    /// One RGBA per polyline of [`edges`](Self::edges), `None` for an edge the file does
    /// not style; empty when nothing is styled.
    pub fn edge_colours(&self) -> Vec<Option<[f32; 4]>> {
        colours_of(self.call(self.scene.api.cadaclysm_node_edge_colors))
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

    /// Its feature edges as cubic Bézier curves -- exact where the file's curves were,
    /// where [`Node::edges`] are their chords. Builds the geometry if needed.
    pub fn edge_beziers(&self) -> Beziers<'s> {
        Beziers::from_raw(self.call(self.scene.api.cadaclysm_node_edge_beziers))
    }

    /// [`Node::edge_beziers`] in `double`: the same segments, unnarrowed.
    pub fn edge_beziers64(&self) -> Beziers64<'s> {
        Beziers64::from_raw(self.call(self.scene.api.cadaclysm_node_edge_beziers64))
    }

    /// Its free curves as cubic Béziers; see [`Node::edge_beziers`].
    pub fn curve_beziers(&self) -> Beziers<'s> {
        Beziers::from_raw(self.call(self.scene.api.cadaclysm_node_curve_beziers))
    }

    /// [`Node::curve_beziers`] in `double`; see [`Node::edge_beziers64`].
    pub fn curve_beziers64(&self) -> Beziers64<'s> {
        Beziers64::from_raw(self.call(self.scene.api.cadaclysm_node_curve_beziers64))
    }

    /// Its isocurves as cubic Béziers; see [`Node::edge_beziers`].
    pub fn isocurve_beziers(&self) -> Beziers<'s> {
        Beziers::from_raw(self.call(self.scene.api.cadaclysm_node_isocurve_beziers))
    }

    /// [`Node::isocurve_beziers`] in `double`; see [`Node::edge_beziers64`].
    pub fn isocurve_beziers64(&self) -> Beziers64<'s> {
        Beziers64::from_raw(self.call(self.scene.api.cadaclysm_node_isocurve_beziers64))
    }

    /// The collision body for what this node draws, building its mesh if it is not
    /// built. `hull_budget` is the most triangles a hull may have; 0 asks for the Unity
    /// limit (255) and is not clamped to it. `None` for a node that draws nothing.
    /// Cached per node and budget.
    pub fn collision(&self, hull_budget: u32) -> Option<Collision> {
        let mut raw = sys::CadaclysmCollision {
            size: std::mem::size_of::<sys::CadaclysmCollision>() as u32,
            shape: 0,
            confidence: 0,
            axis: 0,
            frame: [0.0; 16],
            half_extent: [0.0; 3],
            radius: 0.0,
            height: 0.0,
            error: 0.0,
            hull_vertex_count: 0,
            hull_index_count: 0,
        };
        let ok = unsafe { (self.scene.api.cadaclysm_node_collision)(self.scene.raw(), self.index, hull_budget, &mut raw) };
        ok.then(|| Collision {
            shape: raw.shape,
            confidence: raw.confidence,
            axis: raw.axis,
            frame: raw.frame,
            half_extent: raw.half_extent,
            radius: raw.radius,
            height: raw.height,
            error: raw.error,
            hull_vertex_count: raw.hull_vertex_count,
            hull_index_count: raw.hull_index_count,
        })
    }

    /// The convex hull [`Node::collision`] counted, as triangles, copied out. Empty for
    /// a node that draws nothing.
    pub fn collision_hull(&self, hull_budget: u32) -> CollisionHull {
        let raw = unsafe { (self.scene.api.cadaclysm_node_collision_hull)(self.scene.raw(), self.index, hull_budget) };
        unsafe {
            CollisionHull {
                positions: groups::<3>(raw.positions, raw.vertex_count as usize).unwrap_or(&[]).to_vec(),
                indices: borrowed(raw.indices, raw.index_count as usize).to_vec(),
            }
        }
    }

    /// This node and every node under it, parents before children.
    pub fn walk(&self) -> Walk<'s> {
        Walk { stack: vec![*self] }
    }

    // -- the surface path: for a renderer drawing exact surfaces, never triangles --

    /// The box of what this node draws under `placement` (column-major, as
    /// [`Placement::raw_transform`]; `None` for the identity), for a part drawn from its
    /// surfaces: every sample is carried through the convention and the placement before
    /// it is boxed, so it is tighter than placing the corners of [`Node::bounds`]. All
    /// zeros for a part with no surfaces.
    pub fn bounds_placed(&self, placement: Option<&[f64; 16]>) -> Bounds {
        let matrix = placement.map_or(std::ptr::null(), |m| m.as_ptr());
        Bounds::from_raw(unsafe { (self.scene.api.cadaclysm_node_bounds_placed)(self.scene.raw(), self.index, matrix) })
    }

    /// [`Node::bounds_placed`] in `double`: the same box, unnarrowed.
    pub fn bounds_placed64(&self, placement: Option<&[f64; 16]>) -> Bounds64 {
        let matrix = placement.map_or(std::ptr::null(), |m| m.as_ptr());
        Bounds64::from_raw(unsafe { (self.scene.api.cadaclysm_node_bounds_placed64)(self.scene.raw(), self.index, matrix) })
    }

    /// Whether its mesh has been built and is held -- by [`Scene::realize_all`], by an
    /// ask for it, or by anything else that needed it.
    pub fn is_meshed(&self) -> bool {
        self.call(self.scene.api.cadaclysm_node_is_meshed)
    }

    /// Its face boundaries taken from its trimmed surfaces -- the outline that costs no
    /// tessellation, where [`Node::edges`] meshes the part. In the surfaces' own frame
    /// (see [`Scene::surface_matrix`]); empty without surfaces.
    pub fn surface_edges(&self) -> Polylines<'s> {
        Polylines::from_raw(self.call(self.scene.api.cadaclysm_node_surface_edges))
    }

    /// Its edges as the exact curves, where the reader has them without meshing -- a
    /// Rhino extrusion's rims are its profile -- and empty everywhere else, so a caller
    /// drawing from surfaces tries this before [`Node::surface_edges`], whose trims are
    /// thinned to the mesh tolerance. The same segments as [`Node::edge_beziers`], in the
    /// same space: not the surfaces' frame, so no [`Scene::surface_matrix`].
    pub fn surface_edge_beziers(&self) -> Beziers<'s> {
        Beziers::from_raw(self.call(self.scene.api.cadaclysm_node_surface_edge_beziers))
    }

    /// [`edge_colours`](Self::edge_colours) for [`surface_edges`](Self::surface_edges).
    pub fn surface_edge_colours(&self) -> Vec<Option<[f32; 4]>> {
        colours_of(self.call(self.scene.api.cadaclysm_node_surface_edge_colors))
    }

    /// Its isocurves taken from its trimmed surfaces and clipped to the trims, without
    /// meshing; a flat face gets none. In the surfaces' frame; empty without surfaces.
    pub fn surface_isocurves(&self) -> Polylines<'s> {
        Polylines::from_raw(self.call(self.scene.api.cadaclysm_node_surface_isocurves))
    }

    /// Where the segment `from`..`to` first meets this part's surfaces, or `None` where
    /// it meets none. Exact, and in the surfaces' own frame: carry a ray from the
    /// scene's space through the inverse of [`Scene::surface_matrix`] first.
    pub fn surface_pick(&self, from: [f64; 3], to: [f64; 3]) -> Option<[f64; 3]> {
        let mut hit = [0.0f64; 3];
        let ok = unsafe {
            (self.scene.api.cadaclysm_node_surface_pick)(self.scene.raw(), self.index, from.as_ptr(), to.as_ptr(), hit.as_mut_ptr())
        };
        ok.then_some(hit)
    }

    /// A coarse mesh over its surfaces for what needs triangles and not a picture (ray
    /// tracing, distance fields): each face gridded `cells` by `cells`, never welded,
    /// built once per part at the first size asked. Empty without surfaces or for zero
    /// cells.
    pub fn surface_proxy_mesh(&self, cells: u32) -> Mesh<'s> {
        self.mesh_of(unsafe { (self.scene.api.cadaclysm_node_surface_proxy_mesh)(self.scene.raw(), self.index, cells) })
    }

    /// About how many triangles [`Node::mesh`] would give, without building it; `-1`
    /// where the reader cannot say without doing the work. Treat `-1` as unknown, never
    /// as zero.
    pub fn triangle_estimate(&self) -> i64 {
        self.call(self.scene.api.cadaclysm_node_triangle_estimate)
    }

    /// This node's own wireframe as SVG text, in its own frame -- [`Scene::svg_text`]'s
    /// `options`, read from just this node rather than every placement.
    pub fn svg_text(&self, options: &SvgOptions) -> Result<String> {
        let api = self.scene.api;
        let raw = build_svg_options(api, options, self.scene.default_up());
        let ptr = unsafe { (api.cadaclysm_node_svg_text)(self.scene.raw(), self.index, &raw) };
        if ptr.is_null() {
            let reason = last_error(api);
            return Err(Error::new(if reason.is_empty() { "svg".to_string() } else { reason }));
        }
        Ok(unsafe { text(ptr) })
    }

    /// [`Node::svg_text`] written to `path` by the library itself.
    pub fn svg(&self, path: impl AsRef<Path>, options: &SvgOptions) -> Result<()> {
        let path = path.as_ref();
        let c_path = c_path(path)?;
        let api = self.scene.api;
        let raw = build_svg_options(api, options, self.scene.default_up());
        if unsafe { (api.cadaclysm_node_svg)(self.scene.raw(), self.index, c_path.as_ptr(), &raw) } {
            return Ok(());
        }
        let reason = last_error(api);
        Err(Error::new(if reason.is_empty() { format!("could not write {}", path.display()) } else { reason }))
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

// ---- svg ----------------------------------------------------------------------------

/// Which axis is up -- `CadaclysmSvgOptions::up`. `None` in [`SvgOptions::up`] keeps
/// the scene's own convention: [`Up::Y`] for [`Convention::Unity`]/[`Convention::YUp`],
/// [`Up::Z`] otherwise -- and [`Up::Z`] for a solid, which carries no convention of its
/// own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Up {
    /// Y is up.
    Y,
    /// Z is up.
    Z,
}

/// One of the seven camera angles [`SvgOptions::view`] understands -- the same table
/// `cadaclysm_viewer.VIEWS` gives Python's `show()` and `svg()` both. Degrees
/// (azimuth, elevation): [`SvgView::angles`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SvgView {
    /// (-90, 0) -- looking from -Y.
    Front,
    /// (90, 0) -- looking from +Y.
    Back,
    /// (180, 0) -- looking from -X.
    Left,
    /// (0, 0) -- looking from +X.
    Right,
    /// (-90, 90) -- looking straight down.
    Top,
    /// (-90, -90) -- looking straight up.
    Bottom,
    /// (-50, 28) -- the viewer's own default angle.
    #[default]
    Iso,
}

impl SvgView {
    /// This view's (azimuth, elevation) in degrees.
    fn angles(self) -> (f64, f64) {
        match self {
            SvgView::Front => (-90.0, 0.0),
            SvgView::Back => (90.0, 0.0),
            SvgView::Left => (180.0, 0.0),
            SvgView::Right => (0.0, 0.0),
            SvgView::Top => (-90.0, 90.0),
            SvgView::Bottom => (-90.0, -90.0),
            SvgView::Iso => (-50.0, 28.0),
        }
    }
}

/// How an SVG drawing is made -- the camera in the viewer's words, the page, the pen
/// and which line sets. Mirrors `CadaclysmSvgOptions`; [`SvgOptions::default`] is the
/// defaults `cadaclysm_svg_options_init` fills. `view` supplies `azimuth`/`elevation`
/// unless they are set directly; `up` falls back to the scene's own convention (a solid
/// falls back to [`Up::Z`], carrying no convention of its own). Passed to
/// [`Scene::svg_text`], [`Scene::svg`], [`Node::svg_text`], [`Node::svg`] and, over the
/// kernel, [`blacksmith::Solid::svg_text`]/[`blacksmith::Solid::svg`]. A refused option
/// (an out-of-range `fov`, say) is an [`Error`] naming the field, worded by the library
/// itself.
#[derive(Clone, Debug, PartialEq)]
pub struct SvgOptions {
    /// front back left right top bottom iso -- fills `azimuth`/`elevation` unless they
    /// are set directly. Default [`SvgView::Iso`].
    pub view: SvgView,
    /// Degrees about the up axis from +X, overriding `view`'s: -90 looks from -Y, the
    /// front. `None` keeps `view`'s own.
    pub azimuth: Option<f64>,
    /// Degrees above the horizon, overriding `view`'s. `None` keeps `view`'s own.
    pub elevation: Option<f64>,
    /// `None` keeps the scene's own convention -- [`Up::Y`] for
    /// [`Convention::Unity`]/[`Convention::YUp`], [`Up::Z`] otherwise (and always
    /// [`Up::Z`] over the kernel, a solid carrying no convention of its own).
    pub up: Option<Up>,
    /// Vertical field of view in degrees; 0 (the default) is orthographic.
    pub fov: f64,
    /// The page's viewBox width and height, page units; 0 is 1000.
    pub width: f64,
    pub height: f64,
    /// Fraction of the content's extent left each side. Default 0.05.
    pub margin: f64,
    /// How far a written curve may stray, in page units. Default 0.1.
    pub tolerance: f64,
    /// The pen colour, `0xRRGGBB`. Default black.
    pub stroke: u32,
    /// The pen's width, page units. Default 1.
    pub stroke_width: f64,
    /// `0xRRGGBB`, or `None` (the default) for no `<rect>` behind the drawing -- the
    /// page left to whatever the viewer composites it onto.
    pub background: Option<u32>,
    /// Each shape's feature edges -- the exact curves the flattened polylines are drawn
    /// from. Default `true`.
    pub edges: bool,
    /// Each shape's free curves -- the ones that are not the edge of any face (ignored
    /// over the kernel, a solid having none of its own). Default `false`.
    pub curves: bool,
    /// Each shape's isocurves -- the constant-parameter lines across a curved face
    /// (ignored over the kernel too). Default `false`.
    pub isocurves: bool,
    /// Write every line as straight segments within `tolerance`, instead of being
    /// fitted back to cubic Béziers. Default `false`.
    pub polylines: bool,
}

impl Default for SvgOptions {
    /// The defaults `cadaclysm_svg_options_init` fills: the viewer's iso, orthographic,
    /// a 1000-square page, black edges one unit wide on nothing.
    fn default() -> SvgOptions {
        SvgOptions {
            view: SvgView::Iso,
            azimuth: None,
            elevation: None,
            up: None,
            fov: 0.0,
            width: 1000.0,
            height: 1000.0,
            margin: 0.05,
            tolerance: 0.1,
            stroke: 0x00_0000,
            stroke_width: 1.0,
            background: None,
            edges: true,
            curves: false,
            isocurves: false,
            polylines: false,
        }
    }
}

/// `CadaclysmSvgOptions::background`'s "none" value -- `CADACLYSM_SVG_TRANSPARENT`, the
/// same on both headers.
const SVG_TRANSPARENT: u32 = 0xFFFF_FFFF;

/// `options` packed into a `CadaclysmSvgOptions`: `view` fills `azimuth`/`elevation`
/// unless they are set directly, `up` falls back to `default_up`. `cadaclysm_svg_options_init`
/// fills the struct first -- `size` included -- so a field this crate never sets still
/// carries the library's own default rather than a zeroed struct's.
fn build_svg_options(api: &Api, options: &SvgOptions, default_up: Up) -> sys::CadaclysmSvgOptions {
    let mut raw: sys::CadaclysmSvgOptions = unsafe { std::mem::zeroed() };
    unsafe { (api.cadaclysm_svg_options_init)(&mut raw) };
    let (base_azimuth, base_elevation) = options.view.angles();
    raw.up = match options.up.unwrap_or(default_up) {
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
    raw.stroke = options.stroke;
    raw.background = options.background.unwrap_or(SVG_TRANSPARENT);
    raw.flags = u32::from(options.edges)
        | (u32::from(options.curves) << 1)
        | (u32::from(options.isocurves) << 2)
        | (u32::from(options.polylines) << 3);
    raw
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

    /// The scene's C handle, for libraries that take a `CadaclysmScene *` -- the render
    /// libraries' `cadaclysm_render_add_scene`. Valid until this `Scene` is dropped or
    /// closed; the pointee is opaque.
    pub fn as_ptr(&self) -> *const std::ffi::c_void {
        self.handle.as_ptr().cast()
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

    /// [`Scene::bounds`] in `double`: the same union box, unnarrowed. **This meshes all
    /// of it**, being the only way to know how far it reaches.
    pub fn bounds64(&self) -> Bounds64 {
        Bounds64::from_raw(unsafe { (self.api.cadaclysm_bounds64)(self.raw()) })
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

    /// What the reader built but the geometry stage could not finish: a face that
    /// would not trim, a surface that would not mesh. [`Scene::diagnostics`] is what
    /// the file held that could not be read; this is what the geometry did.
    pub fn geometry_diagnostics(&self) -> Vec<String> {
        let count = unsafe { (self.api.cadaclysm_geometry_diagnostic_count)(self.raw()) };
        (0..count).map(|i| unsafe { text((self.api.cadaclysm_geometry_diagnostic)(self.raw(), i)) }).collect()
    }

    /// The file's mechanism, as rigid bodies -- see [`Link`]. Empty where the file
    /// names no kinematic links.
    pub fn links(&self) -> Vec<Link<'_>> {
        let count = unsafe { (self.api.cadaclysm_link_count)(self.raw()) };
        (0..count).map(|index| Link { scene: self, index }).collect()
    }

    /// The file's mechanism, as connections between links -- see [`Joint`]. Empty
    /// where the file names no kinematic joints.
    pub fn joints(&self) -> Vec<Joint<'_>> {
        let count = unsafe { (self.api.cadaclysm_joint_count)(self.raw()) };
        (0..count).map(|index| Joint { scene: self, index }).collect()
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

    /// [`Scene::realize_all`], leaving alone every node that carries surfaces when
    /// `skip_surfaced` is true: a renderer drawing those from their surfaces never pays
    /// for their triangles. Returns how many were built.
    pub fn realize_meshes(&self, skip_surfaced: bool) -> u32 {
        unsafe { (self.api.cadaclysm_realize_meshes)(self.raw(), u32::from(skip_surfaced)) }
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

    /// Drop every mesh the scene has built; the next ask rebuilds. Takes `&mut self`:
    /// every [`Mesh`] and [`Polylines`] borrowed from the scene is over freed memory
    /// afterwards, and the borrow checker is what stops one being read.
    pub fn forget_meshes(&mut self) {
        unsafe { (self.api.cadaclysm_forget_meshes)(self.raw().cast_mut()) }
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

    /// [`Up::Y`] or [`Up::Z`]: which axis is up by default, from [`Scene::convention`]
    /// -- [`Convention::Unity`] and [`Convention::YUp`] give [`Up::Y`], every other
    /// convention [`Up::Z`]. What [`SvgOptions::up`] falls back to when left `None`.
    /// [`FILE_UNITS`] and [`UV_WORLD`] are masked out first, since they OR into the
    /// packed convention this scene carries.
    fn default_up(&self) -> Up {
        let base = self.convention & !(FILE_UNITS | UV_WORLD);
        if base == Convention::Unity as u32 || base == Convention::YUp as u32 {
            Up::Y
        } else {
            Up::Z
        }
    }

    /// Every visible placement's wireframe as SVG text, from the camera `options`
    /// describes -- the library's own camera, not a viewer. See [`SvgOptions`].
    /// Borrowed by the library: copied out before this returns, and replaced by this
    /// scene's next `svg_text` or `svg` call.
    pub fn svg_text(&self, options: &SvgOptions) -> Result<String> {
        let api = self.api;
        let raw = build_svg_options(api, options, self.default_up());
        let ptr = unsafe { (api.cadaclysm_scene_svg_text)(self.raw(), &raw) };
        if ptr.is_null() {
            let reason = last_error(api);
            return Err(Error::new(if reason.is_empty() { "svg".to_string() } else { reason }));
        }
        Ok(unsafe { text(ptr) })
    }

    /// [`Scene::svg_text`] written to `path` by the library itself.
    pub fn svg(&self, path: impl AsRef<Path>, options: &SvgOptions) -> Result<()> {
        let path = path.as_ref();
        let c_path = c_path(path)?;
        let api = self.api;
        let raw = build_svg_options(api, options, self.default_up());
        if unsafe { (api.cadaclysm_scene_svg)(self.raw(), c_path.as_ptr(), &raw) } {
            return Ok(());
        }
        let reason = last_error(api);
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

    /// A FEM edge and vertex are read out of the raw structs field for field, with the
    /// header's own layout under them. Needs no library: the two `from_raw`s are pure.
    ///
    /// Catches: `faces` and `ends` read from each other's fields (both a pair of `u32` a
    /// swap leaves in range), `face_b`/`end_b` filled with `0` where the ABI said
    /// [`NONE`] (`0` is a real face and a real vertex), `nodes` and `runs` lent from one
    /// pointer, and a `point` read as anything but three doubles in order.
    #[test]
    fn a_fem_edge_and_vertex_are_read_field_for_field() {
        let nodes = [7u32, 8, 9, 10, 11];
        let runs = [0u32, 3];
        let raw = sys::CadaclysmFemEdge {
            id: 19,
            nodes: nodes.as_ptr(),
            node_count: nodes.len() as u32,
            runs: runs.as_ptr(),
            run_count: runs.len() as u32,
            face_a: 0,
            face_b: NONE,
            end_a: 4,
            end_b: 0,
            closed: false,
            seam: true,
        };
        let edge = unsafe { FemEdge::from_raw(&raw) };
        // The id is the body's own, not the index it was read at.
        assert_eq!(edge.id, 19);
        assert_eq!(edge.nodes, nodes);
        assert_eq!(edge.runs, runs);
        // `0` is a real face and a real vertex; only the second of each pair is ever NONE.
        assert_eq!(edge.faces, (0, NONE));
        assert_eq!(edge.ends, (4, 0));
        assert!(!edge.closed && edge.seam);
        // Each run as its own polyline, the last to the end -- what `runs` is for.
        assert_eq!(edge.chains().collect::<Vec<_>>(), [&nodes[..3], &nodes[3..]]);
        let one = sys::CadaclysmFemEdge { run_count: 1, closed: true, ..raw };
        let one = unsafe { FemEdge::from_raw(&one) };
        assert_eq!(one.chains().collect::<Vec<_>>(), [&nodes[..]]);

        let at = sys::CadaclysmFemVertex { node: 0, point: [1.5, -2.5, 3.5], has_position: true };
        let at = FemVertex::from_raw(&at);
        // Node 0 is a real node, not a sentinel -- and the point is in x, y, z order.
        assert_eq!((at.node, at.point, at.has_position), (0, [1.5, -2.5, 3.5], true));
        let none = sys::CadaclysmFemVertex { node: NONE, point: [0.0; 3], has_position: false };
        let none = FemVertex::from_raw(&none);
        assert!(none.node == NONE && !none.has_position && none.point == [0.0; 3]);

        // The header's own sizes, which `#[repr(C)]` reproduces: a wrong scalar width
        // shifts every field after it without changing a name (`tests/bindings.rs` pins
        // the fields; this pins what they add up to). Taken from a C compiler over the
        // header's own four declarations, not from these -- 24, 104, 56, 40 -- so the
        // padding is the ABI's rather than a restatement of what Rust happened to do.
        assert_eq!(std::mem::size_of::<sys::CadaclysmFemOptions>(), 24);
        assert_eq!(std::mem::size_of::<sys::CadaclysmFemMeshView>(), 104);
        assert_eq!(std::mem::size_of::<sys::CadaclysmFemEdge>(), 56);
        assert_eq!(std::mem::size_of::<sys::CadaclysmFemVertex>(), 40);
    }

    /// Far out, `f64` keeps what `f32` cannot: a corner at y = -2600000.987654321 is
    /// -2600001.0 in `f32` (spacing 0.25 there). Catches: `mesh64`/`bounds64` returning
    /// the f32 mesh's data widened rather than the document's own unnarrowed positions.
    ///
    /// Needs the real library (`CADACLYSM_LIBRARY`), unlike every other test in this
    /// module -- this crate's own tests otherwise never open one, on purpose (see the
    /// crate's `Cargo.toml`). Skips quietly rather than failing a `cargo test` run that
    /// has no library to load, which is the common case for this published crate.
    #[test]
    fn mesh64_and_bounds64_keep_coordinates_far_from_the_origin() {
        let path = std::env::temp_dir().join("cadaclysm-rust-far64.scad");
        if std::fs::write(&path, "translate([1000000.123456789, -2600000.987654321, 450.5]) cube(1);").is_err() {
            eprintln!("skipped: could not write a scratch .scad file");
            return;
        }
        let scene = match open(&path) {
            Ok(scene) => scene,
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the far-from-origin cube with)");
                return;
            }
        };
        let node = scene.walk().find(|n| n.can_mesh()).expect("the translated cube has a meshable node");

        let mesh64 = node.mesh64().expect("mesh64 for a node with triangles");
        assert!(
            mesh64.positions.iter().any(|p| (p[1] + 2_600_000.987_654_321).abs() < 1e-6),
            "mesh64 lost the far low-y corner: {:?}",
            mesh64.positions
        );
        assert!(
            mesh64.positions.iter().any(|p| ((p[1] as f32) as f64 - p[1]).abs() > 1e-3),
            "mesh64 carries no coordinate f32 cannot hold, so this test cannot tell mesh64 from mesh widened"
        );

        let (b64, b32) = (node.bounds64(), node.bounds());
        assert!((b64.min[1] + 2_600_000.987_654_321).abs() < 1e-6, "bounds64 lost the far corner: {:?}", b64.min);
        assert!(
            (b64.min[1] - b32.min[1] as f64).abs() > 1e-3,
            "bounds64 agrees with bounds narrowed to the bit, so it is not exact where f32 is not: {} vs {}",
            b64.min[1],
            b32.min[1]
        );

        let scene_b64 = scene.bounds64();
        assert!((scene_b64.min[1] + 2_600_000.987_654_321).abs() < 1e-6, "the scene's bounds64 lost the far corner");
    }
}
