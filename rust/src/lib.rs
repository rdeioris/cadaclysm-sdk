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
//! A [`Scene`] is `Send` and `Sync`: the ABI's accessors take a `const` handle, which is
//! what lets [`Scene::realize_all`] run on one thread while another reads
//! [`Scene::realized`] or calls [`Scene::cancel`]. Silhouette queries
//! ([`Node::silhouette_beziers`]) are serialised by a per-scene lock, because the library
//! answers them from one slot per scene that the next call replaces. This section makes no
//! claim about any other accessor that returns something the library lends from a
//! per-scene slot.

use std::ffi::{c_char, CStr, CString, OsStr};
use std::fmt;
use std::hash::{Hash, Hasher};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::sync::Mutex;

mod loader;
pub mod blacksmith;
pub mod sys;
pub mod view;

use sys::Api;

use view::objects::{present, Shown};
use view::{Camera, ViewOptions};

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
    ids: Vec<u32>,
}

impl Error {
    fn new(message: impl Into<String>) -> Error {
        Error { message: message.into(), ids: Vec::new() }
    }

    /// This error with the ids a [`blacksmith::Sketch`] refusal names.
    pub(crate) fn with_ids(mut self, ids: Vec<u32>) -> Error {
        self.ids = ids;
        self
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

/// The library's own colour parse, shared by [`packed`] (this crate's own paint API,
/// [`blacksmith::coloured`]/[`blacksmith::edges_coloured`], calls the kernel library's
/// own copy instead): `Some((r, g, b))` in 0..1, or `None` for text the library refuses.
fn parse_colour(colour: &str) -> Result<Option<[f64; 3]>> {
    let api = api()?;
    let colour_text = c_string("colour", colour)?;
    let mut out = [0.0f64; 3];
    if unsafe { (api.cadaclysm_parse_colour)(colour_text.as_ptr(), out.as_mut_ptr()) } {
        Ok(Some(out))
    } else {
        Ok(None)
    }
}

/// A colour packed `0xRRGGBB` from colour text -- `"#rgb"`, `"#rrggbb"` or a CSS colour
/// name, matched ASCII case-insensitively -- read by the library's own parser. For a host
/// that wants the number itself; [`SvgOptions::stroke`]/[`SvgOptions::background`] take the
/// text directly, as an [`SvgColour`].
pub fn packed(colour: &str) -> Result<u32> {
    let [r, g, b] = parse_colour(colour)?.ok_or_else(|| {
        Error::new(format!("colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '{colour}'"))
    })?;
    Ok(((r * 255.0).round() as u32) << 16 | ((g * 255.0).round() as u32) << 8 | (b * 255.0).round() as u32)
}

/// A colour [`SvgOptions::stroke`]/[`SvgOptions::background`] take: a packed `0xRRGGBB`,
/// or colour text -- `"#rgb"`, `"#rrggbb"` or a CSS colour name, matched ASCII
/// case-insensitively. Either converts with `.into()`: `stroke: "navy".into()`,
/// `stroke: 0x00_0080.into()`. The text is read when the drawing is made, by the library
/// whose drawing it is (the reader's parser for a scene, the kernel's for a solid); text it
/// refuses, or a number past `0xFFFFFF`, is an [`Error`] naming the field.
#[derive(Clone, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum SvgColour {
    Packed(u32),
    Text(String),
}

impl From<u32> for SvgColour {
    fn from(packed: u32) -> Self {
        SvgColour::Packed(packed)
    }
}

impl From<&str> for SvgColour {
    fn from(text: &str) -> Self {
        SvgColour::Text(text.to_owned())
    }
}

impl From<String> for SvgColour {
    fn from(text: String) -> Self {
        SvgColour::Text(text)
    }
}

impl SvgColour {
    /// `0xRRGGBB`: a number range-checked, text through `parse` (the reader's or the
    /// kernel's own parser, `None` where it refuses). `what` names the field.
    pub(crate) fn packed_with(&self, what: &str, parse: impl Fn(&str) -> Result<Option<[f64; 3]>>) -> Result<u32> {
        match self {
            SvgColour::Packed(packed) if *packed <= 0xFF_FFFF => Ok(*packed),
            SvgColour::Packed(packed) => {
                Err(Error::new(format!("{what}: a packed colour is 0x000000..0xFFFFFF, not {packed:#X}")))
            }
            SvgColour::Text(text) => {
                let [r, g, b] = parse(text)?.ok_or_else(|| {
                    Error::new(format!(
                        "{what}: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or 0xRRGGBB, not '{text}'"
                    ))
                })?;
                Ok(((r * 255.0).round() as u32) << 16 | ((g * 255.0).round() as u32) << 8 | (b * 255.0).round() as u32)
            }
        }
    }
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

    /// The same curves in memory of the program's own.
    pub fn copy(&self) -> Beziers64Data {
        Beziers64Data { points: self.points.to_vec(), weights: self.weights.to_vec() }
    }
}

/// A [`Beziers64`] in memory of the program's own: what [`Node::silhouette_beziers`] and
/// [`blacksmith::Solid::silhouette_beziers`] return. Four control points and four weights a
/// curve, as [`Beziers64`] has them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Beziers64Data {
    pub points: Vec<[f64; 3]>,
    pub weights: Vec<f64>,
}

impl Beziers64Data {
    /// How many curves.
    pub fn count(&self) -> usize {
        self.weights.len() / 4
    }

    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    /// One curve's four control points at a time.
    pub fn iter(&self) -> impl Iterator<Item = &[[f64; 3]]> {
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

    /// This brep with its free edges sewn, and what was sewn, as a new `Brep` and a
    /// [`SewReport`]; this one is left as it was. Two free edges become one shared edge
    /// where both their ends coincide within `vertex` -- by default the rounding
    /// [`Brep::manifold`] merges vertices at -- and their curves lie within `tolerance` of
    /// each other, by default `vertex` too, so only edges that are one curve written
    /// twice are joined. A larger `tolerance` also joins two curves between the same
    /// two vertices that part by up to it; `vertex` is what decides which edges are
    /// candidates at all, and raising it is what could close a slot. Nothing moves.
    pub fn sewed(&self, tolerance: Option<f64>, vertex: Option<f64>) -> Result<(Brep, SewReport)> {
        let mut counts = [0u32; 4];
        let mut gaps = [0f64; 3];
        let pointer = unsafe {
            (self.api.cadaclysm_brep_sew)(
                self.pointer(),
                tolerance.unwrap_or(f64::NAN),
                vertex.unwrap_or(f64::NAN),
                counts.as_mut_ptr(),
                gaps.as_mut_ptr(),
            )
        };
        match NonNull::new(pointer.cast_mut()) {
            Some(pointer) => Ok((
                Brep { pointer, api: self.api },
                SewReport {
                    pairs: counts[0],
                    free_before: counts[1],
                    free_after: counts[2],
                    refused: counts[3],
                    worst_gap: gaps[0],
                    tolerance: gaps[1],
                    vertex: gaps[2],
                },
            )),
            None => {
                let reason = last_error(self.api);
                Err(Error::new(if reason.is_empty() { "sew".to_string() } else { reason }))
            }
        }
    }

    /// What is wrong with this brep, as a [`HealthReport`]: the free edges (the sides one face
    /// bounds) and the wires they chain into, each with its nearest partner and the gap to it;
    /// the features below `tolerance`; the loose edges; and what [`Brep::sewed`] would join and
    /// leave. Nothing moves. `tolerance` is an absolute length, by default (`None`, or a value
    /// that is not finite and positive) `1e-4` times the body's diagonal; the report says what
    /// was used. `mesh` also meshes the brep and reports where the mesh cracks
    /// ([`HealthReport::cracks`]); without it `cracks` is `None`.
    pub fn health(&self, tolerance: Option<f64>, mesh: bool) -> Result<HealthReport> {
        let api = self.api;
        let handle = unsafe { (api.cadaclysm_brep_health)(self.pointer(), tolerance.unwrap_or(f64::NAN), mesh) };
        let fail = || reader_error(api, "health");
        unsafe {
            health_from(
                handle,
                api.cadaclysm_brep_health_free,
                api.cadaclysm_brep_health_summary,
                [api.cadaclysm_brep_health_free_edges, api.cadaclysm_brep_health_wires, api.cadaclysm_brep_health_small],
                api.cadaclysm_brep_health_crack_edges,
                &fail,
            )
        }
    }

    /// This brep with its small features removed, and what was done, as a new `Brep` and a
    /// [`HealReport`]; this one is left as it was. It heals what [`Brep::health`] lists as
    /// small at the same `tolerance`: short and collapsed edges, sliver and tiny faces, small
    /// holes. Every fix is a vertex merge, and an edge it moves records how far as its
    /// [`Brep::edge_tolerance`]. A guard compares the result's health with this one's and
    /// refuses fixes that made it worse ([`HealReport::guarded`]). `kinds` switches each kind
    /// of fix ([`HealKinds::default`] heals all three); a kind switched off is refused as
    /// `"toggled"`. `tolerance` as [`Brep::health`]'s.
    pub fn healed(&self, tolerance: Option<f64>, kinds: HealKinds) -> Result<(Brep, HealReport)> {
        let api = self.api;
        let handle = unsafe { (api.cadaclysm_brep_healed)(self.pointer(), tolerance.unwrap_or(f64::NAN), kinds.flags()) };
        let fail = || reader_error(api, "healed");
        unsafe {
            heal_from(
                handle,
                api.cadaclysm_brep_heal_free,
                api.cadaclysm_brep_heal_summary,
                api.cadaclysm_brep_heal_fixes,
                api.cadaclysm_brep_heal_refused,
                &fail,
                |h| NonNull::new((api.cadaclysm_brep_heal_body)(h).cast_mut()).map(|pointer| Brep { pointer, api }),
            )
        }
    }

    /// How far brep edge `edge` (as a [`HealFix`] or [`FreeEdge`] names one) may lie off its
    /// curve: 0 for an exact edge, the distance healing (or sewing) moved it where that is
    /// recorded, `None` when no trim names the id (an edge healing removed).
    pub fn edge_tolerance(&self, edge: u32) -> Option<f64> {
        let t = unsafe { (self.api.cadaclysm_brep_edge_tolerance)(self.pointer(), edge) };
        if t.is_nan() {
            None
        } else {
            Some(t)
        }
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

    /// Every pair of triangles that pass through each other, as `(a, b)` with `a < b`,
    /// sorted: an edge of one through the other's interior. Their B-rep faces are
    /// [`FemMesh::triangle_face`]`[a]` and `[b]`.
    ///
    /// **Computed for every body, open or closed.** The census [`FemMesh::watertight`],
    /// [`FemMesh::open_edges`] and [`FemMesh::folded_edges`] report is topological and
    /// cannot see a surface passing through itself; a mesh is ready for a volume mesher
    /// when it is [`FemMesh::watertight`] **and** this is empty -- Gmsh refuses one that
    /// crosses. A copy.
    pub fn crossings(&self) -> Result<Vec<(u32, u32)>> {
        let count = unsafe { (self.api.cadaclysm_fem_mesh_crossing_count)(self.raw()) };
        (0..count)
            .map(|i| {
                let (mut a, mut b) = (0u32, 0u32);
                if !unsafe { (self.api.cadaclysm_fem_mesh_crossing)(self.raw(), i, &mut a, &mut b) } {
                    let reason = last_error(self.api);
                    return Err(Error::new(if reason.is_empty() { format!("fem mesh crossing {i}") } else { reason }));
                }
                Ok((a, b))
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

/// What [`Brep::sewed`] did, as plain data: the edges it joined (`pairs`), the free
/// edges before and after, how many groups of free edges between the same two
/// vertices it left free (`refused`: too far apart for the tolerance, or more than
/// two), the widest gap it sewed, and the two tolerances it used.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SewReport {
    pub pairs: u32,
    pub free_before: u32,
    pub free_after: u32,
    pub refused: u32,
    pub worst_gap: f64,
    pub tolerance: f64,
    pub vertex: f64,
}

// ---- health and healing -----------------------------------------------------------
//
// One set of report types for both libraries: [`Brep::health`] / [`Brep::healed`] here and
// [`blacksmith::Solid::health`] / [`blacksmith::Solid::healed`] return the same ones, as
// [`Manifold`] is shared.

/// What is wrong with a body, as plain data ([`Brep::health`], [`blacksmith::Solid::health`]):
/// the `tolerance` and `rounding` it judged at and the body's `extent` (its diagonal); the free
/// edges, their wires and the features below the tolerance; the loose edges (`worst_loose` the
/// widest); what sewing would do (`sew_pairs` joined, `sew_refused` groups left,
/// `sew_worst_gap`); `cracks` where the mesh cracks, `None` unless the call asked for the mesh;
/// and `worst_gap`, the widest gap between a free edge and its partner (0 if none).
#[derive(Clone, Debug, PartialEq)]
pub struct HealthReport {
    pub tolerance: f64,
    pub rounding: f64,
    pub extent: f64,
    pub free_edges: Vec<FreeEdge>,
    pub wires: Vec<FreeWire>,
    pub small: Vec<SmallFeature>,
    pub loose_edges: u32,
    pub worst_loose: f64,
    pub sew_pairs: u32,
    pub sew_refused: u32,
    pub sew_worst_gap: f64,
    pub cracks: Option<Cracks>,
    pub worst_gap: f64,
}

impl HealthReport {
    /// The free edges of wire number `wire` (a row of `wires`), in order; empty for no such wire.
    pub fn wire_edges(&self, wire: usize) -> &[FreeEdge] {
        match self.wires.get(wire) {
            Some(w) => window(&self.free_edges, w.first, w.count),
            None => &[],
        }
    }
}

/// One free edge: a side only one face bounds. `trim` is the face's side, `edge` the brep
/// edge it lies on (`None` for a side with no edge), `face` the face it bounds, `wire` its row
/// of [`HealthReport::wires`]; `partner` the nearest free edge across the gap, as a row of
/// [`HealthReport::free_edges`] (`None` if there is none); `shared_ends` how many of its two
/// ends it shares with the partner (2 is what sewing joins); its `length` and the `gap` to the
/// partner (infinite without one).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FreeEdge {
    pub trim: u32,
    pub edge: Option<u32>,
    pub face: u32,
    pub wire: u32,
    pub partner: Option<u32>,
    pub shared_ends: u32,
    pub length: f64,
    pub gap: f64,
}

/// A chain of free edges end to end: the rows `first .. first + count` of
/// [`HealthReport::free_edges`], whether it `closed` on itself, its total `length` and the
/// `widest_gap` from any of its edges to a partner.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FreeWire {
    pub first: u32,
    pub count: u32,
    pub closed: bool,
    pub length: f64,
    pub widest_gap: f64,
}

/// Something below the tolerance: `kind` is `"short_edge"`, `"collapsed_edge"`,
/// `"sliver_face"`, `"tiny_face"`, `"tiny_body"` or `"small_hole"`; `index` its edge, face or
/// body number (a small hole's is its loop number); `size` how small it is.
#[derive(Clone, Debug, PartialEq)]
pub struct SmallFeature {
    pub kind: String,
    pub index: u32,
    pub size: f64,
}

/// What a mesh of the body shows, asked for with `mesh`: whether it is `watertight`, how many
/// mesh edges are `open` (one triangle) or `folded` (more than two), how many pairs of
/// triangles pass through each other (`crossings`), and the body's `edges` the cracks lie
/// along. Only a closed body is counted: an open one's census is empty by design.
#[derive(Clone, Debug, PartialEq)]
pub struct Cracks {
    pub watertight: bool,
    pub open: u32,
    pub folded: u32,
    pub crossings: u32,
    pub edges: Vec<u32>,
}

/// What [`Brep::healed`] (or [`blacksmith::Solid::healed`]) did, as plain data: the
/// `tolerance` it healed at, the furthest any trim the result keeps `moved`, whether the body
/// guard refused fixes (`guarded`), the `fixes` made and the small features `refused`; and the
/// body's health before and after at that tolerance -- its small features, free edges, whether
/// it is closed, and its non-manifold edges. Indices are the input body's.
#[derive(Clone, Debug, PartialEq)]
pub struct HealReport {
    pub tolerance: f64,
    pub moved: f64,
    pub guarded: bool,
    pub fixes: Vec<HealFix>,
    pub refused: Vec<HealRefusal>,
    pub small_before: u32,
    pub small_after: u32,
    pub free_before: u32,
    pub free_after: u32,
    pub closed_before: bool,
    pub closed_after: bool,
    pub nonmanifold_before: u32,
    pub nonmanifold_after: u32,
}

/// One small feature removed: its `kind` (as [`SmallFeature::kind`]), its `index` in the input
/// (as `health` gave it), its `size`, and how far the vertices this fix merged `moved`.
#[derive(Clone, Debug, PartialEq)]
pub struct HealFix {
    pub kind: String,
    pub index: u32,
    pub size: f64,
    pub moved: f64,
}

/// One small feature left, and why: `kind` and `index` as in [`HealFix`]; `why` is
/// `"would_empty_loop"`, `"closed"`, `"seam"`, `"chain"` (a chain wider than the tolerance),
/// `"neighbours_part"` (a sliver's neighbours part), `"uneven"` (uneven sliver sides),
/// `"non_manifold"`, `"has_holes"`, `"body_guard"` (the guard refused the fix), `"toggled"`
/// (its kind switched off) or `"unsupported"` (a tiny body); `figure` the chain's width or the
/// neighbours' gap, else 0.
#[derive(Clone, Debug, PartialEq)]
pub struct HealRefusal {
    pub kind: String,
    pub index: u32,
    pub why: String,
    pub figure: f64,
}

/// Which kinds of fix [`Brep::healed`] (and [`blacksmith::Solid::healed`]) makes -- Rust's
/// spelling of Python's `edges=`, `faces=`, `holes=` keywords. `Default` switches all three
/// on; a kind switched off is refused as `"toggled"`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HealKinds {
    /// Short and collapsed edges.
    pub edges: bool,
    /// Sliver and tiny faces.
    pub faces: bool,
    /// Small holes.
    pub holes: bool,
}

impl Default for HealKinds {
    fn default() -> HealKinds {
        HealKinds { edges: true, faces: true, holes: true }
    }
}

impl HealKinds {
    /// The C ABI's flag bits: 1 edges, 2 faces, 4 holes.
    pub(crate) fn flags(self) -> u32 {
        (if self.edges { 1 } else { 0 }) | (if self.faces { 2 } else { 0 }) | (if self.holes { 4 } else { 0 })
    }
}

/// The health ABI's small-feature kinds, by code.
const HEALTH_KINDS: [&str; 6] = ["short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole"];

/// The heal ABI's refusal reasons, by code.
const HEAL_WHYS: [&str; 11] = [
    "would_empty_loop",
    "closed",
    "seam",
    "chain",
    "neighbours_part",
    "uneven",
    "non_manifold",
    "has_holes",
    "body_guard",
    "toggled",
    "unsupported",
];

fn coded(table: &[&str], code: u32, what: &str) -> Result<String> {
    table
        .get(code as usize)
        .map(|name| name.to_string())
        .ok_or_else(|| Error::new(format!("the library answered {code}, not a {what}")))
}

fn optional_id(id: u32) -> Option<u32> {
    if id == NONE {
        None
    } else {
        Some(id)
    }
}

/// The flat rows of the health C ABI as a [`HealthReport`], index for index as Python's
/// `_health_report`: `counts` eighteen, `sizes` eight, free edges six ids and two sizes a row,
/// wires three and two, small features two and one, the crack edge ids.
#[allow(clippy::too_many_arguments)]
pub(crate) fn health_report(
    counts: &[u32; 18],
    sizes: &[f64; 8],
    free_ids: &[u32],
    free_sizes: &[f64],
    wire_runs: &[u32],
    wire_sizes: &[f64],
    small_items: &[u32],
    small_sizes: &[f64],
    crack_edges: &[u32],
) -> Result<HealthReport> {
    let free_edges = free_ids
        .chunks_exact(6)
        .zip(free_sizes.chunks_exact(2))
        .map(|(id, size)| FreeEdge {
            trim: id[0],
            edge: optional_id(id[1]),
            face: id[2],
            wire: id[3],
            partner: optional_id(id[4]),
            shared_ends: id[5],
            length: size[0],
            gap: size[1],
        })
        .collect();
    let wires = wire_runs
        .chunks_exact(3)
        .zip(wire_sizes.chunks_exact(2))
        .map(|(run, size)| FreeWire { first: run[0], count: run[1], closed: run[2] != 0, length: size[0], widest_gap: size[1] })
        .collect();
    let small = small_items
        .chunks_exact(2)
        .zip(small_sizes)
        .map(|(item, &size)| Ok(SmallFeature { kind: coded(&HEALTH_KINDS, item[0], "feature kind")?, index: item[1], size }))
        .collect::<Result<Vec<_>>>()?;
    let cracks = (counts[12] == 1).then(|| Cracks {
        watertight: counts[13] != 0,
        open: counts[14],
        folded: counts[15],
        crossings: counts[16],
        edges: crack_edges.to_vec(),
    });
    Ok(HealthReport {
        tolerance: sizes[0],
        rounding: sizes[1],
        extent: sizes[2],
        free_edges,
        wires,
        small,
        loose_edges: counts[9],
        worst_loose: sizes[4],
        sew_pairs: counts[10],
        sew_refused: counts[11],
        sew_worst_gap: sizes[5],
        cracks,
        worst_gap: sizes[3],
    })
}

/// The flat rows of the heal C ABI as a [`HealReport`], index for index as Python's
/// `_heal_report`: `counts` eleven, `sizes` two, fixes two ids and two sizes a row, refusals
/// three and one.
pub(crate) fn heal_report(
    counts: &[u32; 11],
    sizes: &[f64; 2],
    fix_items: &[u32],
    fix_sizes: &[f64],
    refused_items: &[u32],
    refused_sizes: &[f64],
) -> Result<HealReport> {
    let fixes = fix_items
        .chunks_exact(2)
        .zip(fix_sizes.chunks_exact(2))
        .map(|(item, size)| {
            Ok(HealFix { kind: coded(&HEALTH_KINDS, item[0], "feature kind")?, index: item[1], size: size[0], moved: size[1] })
        })
        .collect::<Result<Vec<_>>>()?;
    let refused = refused_items
        .chunks_exact(3)
        .zip(refused_sizes)
        .map(|(item, &figure)| {
            Ok(HealRefusal {
                kind: coded(&HEALTH_KINDS, item[0], "feature kind")?,
                index: item[1],
                why: coded(&HEAL_WHYS, item[2], "heal refusal")?,
                figure,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(HealReport {
        tolerance: sizes[0],
        moved: sizes[1],
        guarded: counts[2] != 0,
        fixes,
        refused,
        small_before: counts[3],
        small_after: counts[4],
        free_before: counts[5],
        free_after: counts[6],
        closed_before: counts[7] != 0,
        closed_after: counts[8] != 0,
        nonmanifold_before: counts[9],
        nonmanifold_after: counts[10],
    })
}

/// A row reader of the two-call convention: both buffers null for the count, then filled.
pub(crate) type RowsFn<H> = unsafe extern "C" fn(*const H, *mut u32, *mut f64) -> u32;

/// Frees a report handle on every path out of the function that holds it.
struct Freed<H>(*mut H, unsafe extern "C" fn(*mut H));

impl<H> Drop for Freed<H> {
    fn drop(&mut self) {
        unsafe { (self.1)(self.0) }
    }
}

/// One two-call row reader's rows, `ids` and `sizes` values a row.
unsafe fn report_rows<H>(handle: *const H, read: RowsFn<H>, ids: usize, sizes: usize) -> (Vec<u32>, Vec<f64>) {
    let n = read(handle, ptr::null_mut(), ptr::null_mut()) as usize;
    let (mut a, mut b) = (vec![0u32; ids * n], vec![0f64; sizes * n]);
    if n > 0 {
        read(handle, a.as_mut_ptr(), b.as_mut_ptr());
    }
    (a, b)
}

/// A health handle's report, for either library: `readers` are the free-edge, wire and
/// small-feature row readers; the handle is freed on every path; null is `fail()`.
///
/// # Safety
/// `handle` null or a live health handle the five functions belong to, not used after.
pub(crate) unsafe fn health_from<H>(
    handle: *mut H,
    free: unsafe extern "C" fn(*mut H),
    summary: unsafe extern "C" fn(*const H, *mut u32, *mut f64) -> bool,
    readers: [RowsFn<H>; 3],
    crack_edges: unsafe extern "C" fn(*const H, *mut u32) -> u32,
    fail: &dyn Fn() -> Error,
) -> Result<HealthReport> {
    if handle.is_null() {
        return Err(fail());
    }
    let _freed = Freed(handle, free);
    let (mut counts, mut sizes) = ([0u32; 18], [0f64; 8]);
    if !summary(handle, counts.as_mut_ptr(), sizes.as_mut_ptr()) {
        return Err(fail());
    }
    let (free_ids, free_sizes) = report_rows(handle, readers[0], 6, 2);
    let (wire_runs, wire_sizes) = report_rows(handle, readers[1], 3, 2);
    let (small_items, small_sizes) = report_rows(handle, readers[2], 2, 1);
    let n = crack_edges(handle, ptr::null_mut()) as usize;
    let mut cracks = vec![0u32; n];
    if n > 0 {
        crack_edges(handle, cracks.as_mut_ptr());
    }
    health_report(&counts, &sizes, &free_ids, &free_sizes, &wire_runs, &wire_sizes, &small_items, &small_sizes, &cracks)
}

/// A heal handle's report and its body (`take`, `None` where the library gave none), for
/// either library; the handle is freed on every path, after the body is taken; null is
/// `fail()`.
///
/// # Safety
/// `handle` null or a live heal handle the four functions belong to, not used after.
pub(crate) unsafe fn heal_from<H, T>(
    handle: *mut H,
    free: unsafe extern "C" fn(*mut H),
    summary: unsafe extern "C" fn(*const H, *mut u32, *mut f64) -> bool,
    fixes: RowsFn<H>,
    refused: RowsFn<H>,
    fail: &dyn Fn() -> Error,
    take: impl FnOnce(*const H) -> Option<T>,
) -> Result<(T, HealReport)> {
    if handle.is_null() {
        return Err(fail());
    }
    let _freed = Freed(handle, free);
    let (mut counts, mut sizes) = ([0u32; 11], [0f64; 2]);
    if !summary(handle, counts.as_mut_ptr(), sizes.as_mut_ptr()) {
        return Err(fail());
    }
    let (fix_items, fix_sizes) = report_rows(handle, fixes, 2, 2);
    let (refused_items, refused_sizes) = report_rows(handle, refused, 3, 1);
    let report = heal_report(&counts, &sizes, &fix_items, &fix_sizes, &refused_items, &refused_sizes)?;
    let body = take(handle).ok_or_else(fail)?;
    Ok((body, report))
}

/// The reader's own reason for the last failure on this thread, or `what`.
fn reader_error(api: &Api, what: &str) -> Error {
    let reason = last_error(api);
    Error::new(if reason.is_empty() { what.to_string() } else { reason })
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

/// A connection between two links of the file's mechanism. From [`Scene::joints`].
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

    /// How this joint moves: the kinematic pair naming it, or `None` when the file
    /// gives it none.
    pub fn pair(&self) -> Option<Pair<'s>> {
        let raw = unsafe { (self.scene.api.cadaclysm_joint_pair_kind)(self.scene.raw(), self.index) };
        let kind = PairKind::from_raw(raw)?;
        Some(Pair { scene: self.scene, joint: self.index, kind })
    }
}

// ---- pairs, freedoms and states ---------------------------------------------------

/// Which kind of relative motion a [`Pair`] allows -- `CadaclysmPairKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PairKind {
    Revolute,
    Prismatic,
    Cylindrical,
    Spherical,
    SphericalWithPin,
    Planar,
    Universal,
    Homokinetic,
    Screw,
    FullyConstrained,
    Unconstrained,
    LowOrder,
    Other,
}

impl PairKind {
    /// `None` for -1 (the joint has no pair) or any other value the ABI has not named.
    fn from_raw(raw: i32) -> Option<PairKind> {
        Some(match raw {
            0 => PairKind::Revolute,
            1 => PairKind::Prismatic,
            2 => PairKind::Cylindrical,
            3 => PairKind::Spherical,
            4 => PairKind::SphericalWithPin,
            5 => PairKind::Planar,
            6 => PairKind::Universal,
            7 => PairKind::Homokinetic,
            8 => PairKind::Screw,
            9 => PairKind::FullyConstrained,
            10 => PairKind::Unconstrained,
            11 => PairKind::LowOrder,
            12 => PairKind::Other,
            _ => return None,
        })
    }

    /// The kind's snake_case name, the spelling `cadaclysm_joint_pair_kind_name` uses.
    pub fn name(self) -> &'static str {
        match self {
            PairKind::Revolute => "revolute",
            PairKind::Prismatic => "prismatic",
            PairKind::Cylindrical => "cylindrical",
            PairKind::Spherical => "spherical",
            PairKind::SphericalWithPin => "spherical_with_pin",
            PairKind::Planar => "planar",
            PairKind::Universal => "universal",
            PairKind::Homokinetic => "homokinetic",
            PairKind::Screw => "screw",
            PairKind::FullyConstrained => "fully_constrained",
            PairKind::Unconstrained => "unconstrained",
            PairKind::LowOrder => "low_order",
            PairKind::Other => "other",
        }
    }
}

/// Which motion a [`Freedom`] is -- `CadaclysmMotion`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Motion {
    Rotation,
    Translation,
}

impl Motion {
    fn from_raw(raw: u32) -> Motion {
        match raw {
            1 => Motion::Translation,
            _ => Motion::Rotation,
        }
    }
}

/// Which contact-frame axis a [`Freedom`] is about or along -- `CadaclysmFreedomAxis`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FreedomAxis {
    X,
    Y,
    Z,
}

impl FreedomAxis {
    fn from_raw(raw: u32) -> FreedomAxis {
        match raw {
            1 => FreedomAxis::Y,
            2 => FreedomAxis::Z,
            _ => FreedomAxis::X,
        }
    }
}

/// One degree of freedom of a [`Pair`]: which motion, about or along which
/// contact-frame axis, and its optional range. From [`Pair::freedoms`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Freedom {
    pub motion: Motion,
    pub axis: FreedomAxis,
    /// Radians for a rotation, a length for a translation. `None` for unbounded.
    pub lower: Option<f64>,
    pub upper: Option<f64>,
}

impl Freedom {
    fn from_raw(raw: sys::CadaclysmFreedom) -> Freedom {
        Freedom {
            motion: Motion::from_raw(raw.motion),
            axis: FreedomAxis::from_raw(raw.axis),
            lower: raw.has_lower.then_some(raw.lower),
            upper: raw.has_upper.then_some(raw.upper),
        }
    }
}

/// A kinematic pair: the kind of relative motion a joint allows between its two links.
/// From [`Joint::pair`]; borrows from the scene like [`Joint`].
#[derive(Clone, Copy)]
pub struct Pair<'s> {
    scene: &'s Scene,
    joint: u32,
    kind: PairKind,
}

impl fmt::Debug for Pair<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<Pair {:?}>", self.kind)
    }
}

impl<'s> Pair<'s> {
    pub fn scene(&self) -> &'s Scene {
        self.scene
    }

    pub fn kind(&self) -> PairKind {
        self.kind
    }

    /// The pair's entity type name (`"GEAR_PAIR"`), for [`PairKind::Other`]; `None`
    /// otherwise.
    pub fn type_name(&self) -> Option<String> {
        let raw = unsafe { (self.scene.api.cadaclysm_joint_pair_type)(self.scene.raw(), self.joint) };
        (!raw.is_null()).then(|| unsafe { text(raw) })
    }

    /// The kind by name, finer than [`kind`](Self::kind): the same thirteen names, with
    /// `"gear"` and `"rack_and_pinion"` for the two coupled pairs `kind` reads as
    /// [`PairKind::Other`].
    pub fn kind_name(&self) -> String {
        let raw = unsafe { (self.scene.api.cadaclysm_joint_pair_kind_name)(self.scene.raw(), self.joint) };
        if raw.is_null() {
            self.kind.name().to_string()
        } else {
            unsafe { text(raw) }
        }
    }

    /// The pair's own numbers, in the order `Assembly::pair_with` takes them: `"screw"`
    /// `[pitch]`, `"rack_and_pinion"` `[pinion_radius]`, `"gear"` `[radius_first,
    /// radius_second, ratio, bevel, helical_angle]` (always five, the ratio the second
    /// link's rotation over the first's); empty for every other kind.
    pub fn parameters(&self) -> Vec<f64> {
        let api = self.scene.api;
        let count = unsafe { (api.cadaclysm_joint_pair_parameters)(self.scene.raw(), self.joint, std::ptr::null_mut(), 0) };
        let mut out = vec![0.0; count];
        if count > 0 {
            unsafe { (api.cadaclysm_joint_pair_parameters)(self.scene.raw(), self.joint, out.as_mut_ptr(), count) };
        }
        out
    }

    /// Its pitch -- length per revolution, in the scene's units -- for
    /// [`PairKind::Screw`]; `None` otherwise.
    pub fn pitch(&self) -> Option<f64> {
        let raw = unsafe { (self.scene.api.cadaclysm_joint_pair_pitch)(self.scene.raw(), self.joint) };
        (!raw.is_nan()).then_some(raw)
    }

    fn raw_frames(&self) -> ([f64; 16], [f64; 16]) {
        let mut start = [0.0; 16];
        let mut end = [0.0; 16];
        unsafe { (self.scene.api.cadaclysm_joint_pair_frames)(self.scene.raw(), self.joint, start.as_mut_ptr(), end.as_mut_ptr()) };
        (start, end)
    }

    /// The pair's contact frame fixed in its joint's `start` link, in world
    /// coordinates at the file's rest pose, as 16 column-major doubles --
    /// [`Node::raw_transform`]'s layout.
    pub fn raw_frame_start(&self) -> [f64; 16] {
        self.raw_frames().0
    }

    /// The pair's contact frame fixed in its joint's `end` link, as 16 column-major
    /// doubles.
    pub fn raw_frame_end(&self) -> [f64; 16] {
        self.raw_frames().1
    }

    /// [`Pair::raw_frame_start`] as rows, like [`Node::transform`].
    pub fn frame_start(&self) -> [[f64; 4]; 4] {
        rows(&self.raw_frame_start())
    }

    /// [`Pair::raw_frame_end`] as rows.
    pub fn frame_end(&self) -> [[f64; 4]; 4] {
        rows(&self.raw_frame_end())
    }

    /// Its degrees of freedom, in the reader's per-kind order. A [`State`]'s values
    /// compose in this order.
    pub fn freedoms(&self) -> Vec<Freedom> {
        let api = self.scene.api;
        let count = unsafe { (api.cadaclysm_joint_freedom_count)(self.scene.raw(), self.joint) };
        (0..count)
            .filter_map(|i| {
                let mut raw = std::mem::MaybeUninit::<sys::CadaclysmFreedom>::uninit();
                let ok = unsafe { (api.cadaclysm_joint_freedom)(self.scene.raw(), self.joint, i, raw.as_mut_ptr()) };
                ok.then(|| Freedom::from_raw(unsafe { raw.assume_init() }))
            })
            .collect()
    }
}

/// One row of a [`State`]: the joint it sets, and one value per freedom of its pair, in
/// the pair's freedom order.
#[derive(Clone, Debug)]
pub struct StateValue<'s> {
    pub joint: Joint<'s>,
    pub values: Vec<f64>,
}

/// A named pose of the file's mechanism: a `MECHANISM_STATE_REPRESENTATION`. From
/// [`Scene::states`].
#[derive(Clone, Debug)]
pub struct State<'s> {
    pub index: u32,
    pub name: String,
    /// One row per joint this state sets, in file order.
    pub values: Vec<StateValue<'s>>,
}

/// How a motion sequence leaves a segment for the next: the schema's
/// `interpolation_type` (`cadaclysm_sequence_segment`'s `interpolation`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interpolation {
    Undefined,
    Discontinuous,
    Synchronous,
    Linear,
}

impl Interpolation {
    fn from_raw(raw: u32) -> Interpolation {
        match raw {
            1 => Interpolation::Discontinuous,
            2 => Interpolation::Synchronous,
            3 => Interpolation::Linear,
            _ => Interpolation::Undefined,
        }
    }

    /// `"undefined"`, `"discontinuous"`, `"synchronous"` or `"linear"`.
    pub fn name(&self) -> &'static str {
        match self {
            Interpolation::Undefined => "undefined",
            Interpolation::Discontinuous => "discontinuous",
            Interpolation::Synchronous => "synchronous",
            Interpolation::Linear => "linear",
        }
    }
}

/// One step of a [`Sequence`]: the [`State`] it reaches, its parameter, and how the motion
/// leaves it.
#[derive(Clone, Debug)]
pub struct Segment<'s> {
    pub state: State<'s>,
    pub t: f64,
    pub interpolation: Interpolation,
}

/// A motion the file records: an `INTERPOLATED_CONFIGURATION_SEQUENCE`. From
/// [`Scene::sequences`]. [`Sequence::pose`] poses it at a parameter; see
/// `cadaclysm.h`'s `cadaclysm_pose_sequence` and the spec's seconds rule for playing it on
/// a clock.
#[derive(Clone)]
pub struct Sequence<'s> {
    scene: &'s Scene,
    pub index: u32,
    pub name: String,
    /// Whether the motion returns to its first segment.
    pub closed: bool,
    /// Seconds per parameter unit where the file states a time unit; `None` where it
    /// states none (read the parameter as seconds).
    pub seconds_per_unit: Option<f64>,
    pub segments: Vec<Segment<'s>>,
}

impl std::fmt::Debug for Sequence<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Sequence")
            .field("index", &self.index)
            .field("name", &self.name)
            .field("closed", &self.closed)
            .field("seconds_per_unit", &self.seconds_per_unit)
            .field("segments", &self.segments)
            .finish()
    }
}

impl<'s> Sequence<'s> {
    /// The first segment's parameter.
    pub fn start(&self) -> f64 {
        self.segments.first().map_or(0.0, |s| s.t)
    }

    /// The last segment's parameter (the closing span not included).
    pub fn end(&self) -> f64 {
        self.segments.last().map_or(0.0, |s| s.t)
    }

    /// The mechanism posed by this sequence at parameter `t`, with `ground` held fixed as
    /// [`Scene::pose`] does. A closed sequence wraps, each joint looping on its own keys
    /// (the closing span, last back to first, is the mean of the sequence's spans). Fails
    /// for a `t` that is not finite.
    pub fn pose(&self, t: f64, ground: Option<Link<'_>>) -> Result<Pose<'s>> {
        let ground_index = ground.map_or(NONE, |link| link.index);
        let api = self.scene.api;
        let ptr = unsafe { (api.cadaclysm_pose_sequence)(self.scene.raw(), self.index, t, ground_index) };
        if ptr.is_null() {
            return Err(Error::new(last_error(api)));
        }
        Ok(copy_pose(self.scene, ptr))
    }
}

/// A work schedule's kind: the schema's `IfcWorkScheduleTypeEnum`
/// (`cadaclysm_schedule_kind`). [`ScheduleKind::Other`]'s text is
/// [`WorkSchedule::kind_name`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScheduleKind {
    Planned,
    Actual,
    Baseline,
    NotDefined,
    Other,
}

impl ScheduleKind {
    fn from_raw(raw: u32) -> ScheduleKind {
        match raw {
            0 => ScheduleKind::Planned,
            1 => ScheduleKind::Actual,
            2 => ScheduleKind::Baseline,
            4 => ScheduleKind::Other,
            _ => ScheduleKind::NotDefined,
        }
    }

    /// `"planned"`, `"actual"`, `"baseline"`, `"notdefined"` or `"other"`.
    pub fn name(&self) -> &'static str {
        match self {
            ScheduleKind::Planned => "planned",
            ScheduleKind::Actual => "actual",
            ScheduleKind::Baseline => "baseline",
            ScheduleKind::NotDefined => "notdefined",
            ScheduleKind::Other => "other",
        }
    }
}

/// A task's kind: the schema's `IfcTaskTypeEnum` (`cadaclysm_task_kind`).
/// [`TaskKind::Other`]'s text is [`Task::kind_name`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskKind {
    Attendance,
    Construction,
    Demolition,
    Dismantle,
    Disposal,
    Installation,
    Logistic,
    Maintenance,
    Move,
    Operation,
    Removal,
    Renovation,
    NotDefined,
    Other,
}

impl TaskKind {
    fn from_raw(raw: u32) -> TaskKind {
        match raw {
            0 => TaskKind::Attendance,
            1 => TaskKind::Construction,
            2 => TaskKind::Demolition,
            3 => TaskKind::Dismantle,
            4 => TaskKind::Disposal,
            5 => TaskKind::Installation,
            6 => TaskKind::Logistic,
            7 => TaskKind::Maintenance,
            8 => TaskKind::Move,
            9 => TaskKind::Operation,
            10 => TaskKind::Removal,
            11 => TaskKind::Renovation,
            13 => TaskKind::Other,
            _ => TaskKind::NotDefined,
        }
    }

    /// `"attendance"`, `"construction"`, `"demolition"`, `"dismantle"`, `"disposal"`,
    /// `"installation"`, `"logistic"`, `"maintenance"`, `"move"`, `"operation"`,
    /// `"removal"`, `"renovation"`, `"notdefined"` or `"other"`.
    pub fn name(&self) -> &'static str {
        match self {
            TaskKind::Attendance => "attendance",
            TaskKind::Construction => "construction",
            TaskKind::Demolition => "demolition",
            TaskKind::Dismantle => "dismantle",
            TaskKind::Disposal => "disposal",
            TaskKind::Installation => "installation",
            TaskKind::Logistic => "logistic",
            TaskKind::Maintenance => "maintenance",
            TaskKind::Move => "move",
            TaskKind::Operation => "operation",
            TaskKind::Removal => "removal",
            TaskKind::Renovation => "renovation",
            TaskKind::NotDefined => "notdefined",
            TaskKind::Other => "other",
        }
    }
}

/// How a [`TaskLink`] ties its two tasks: the schema's `IfcSequenceEnum`
/// (`cadaclysm_task_link`'s `kind`). [`LinkKind::Other`]'s text is [`TaskLink::kind_name`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkKind {
    FinishStart,
    StartStart,
    FinishFinish,
    StartFinish,
    NotDefined,
    Other,
}

impl LinkKind {
    fn from_raw(raw: u32) -> LinkKind {
        match raw {
            0 => LinkKind::FinishStart,
            1 => LinkKind::StartStart,
            2 => LinkKind::FinishFinish,
            3 => LinkKind::StartFinish,
            5 => LinkKind::Other,
            _ => LinkKind::NotDefined,
        }
    }

    /// `"finish_start"`, `"start_start"`, `"finish_finish"`, `"start_finish"`,
    /// `"notdefined"` or `"other"`.
    pub fn name(&self) -> &'static str {
        match self {
            LinkKind::FinishStart => "finish_start",
            LinkKind::StartStart => "start_start",
            LinkKind::FinishFinish => "finish_finish",
            LinkKind::StartFinish => "start_finish",
            LinkKind::NotDefined => "notdefined",
            LinkKind::Other => "other",
        }
    }
}

/// What an element is doing on a date: [`ElementState::phase`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Unbuilt,
    Building,
    Built,
    Demolishing,
    Demolished,
}

impl Phase {
    fn from_raw(raw: u32) -> Phase {
        match raw {
            1 => Phase::Building,
            2 => Phase::Built,
            3 => Phase::Demolishing,
            4 => Phase::Demolished,
            _ => Phase::Unbuilt,
        }
    }

    /// `"unbuilt"`, `"building"`, `"built"`, `"demolishing"` or `"demolished"`.
    pub fn name(&self) -> &'static str {
        match self {
            Phase::Unbuilt => "unbuilt",
            Phase::Building => "building",
            Phase::Built => "built",
            Phase::Demolishing => "demolishing",
            Phase::Demolished => "demolished",
        }
    }
}

/// Which of a task's dates [`WorkSchedule::at`] plays.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dates {
    /// The dates the programme planned (`schedule_*`).
    Scheduled,
    /// The dates the work really took (`actual_*`), against which variances are read.
    Actual,
}

impl Dates {
    /// `"scheduled"` or `"actual"`.
    pub fn name(&self) -> &'static str {
        match self {
            Dates::Scheduled => "scheduled",
            Dates::Actual => "actual",
        }
    }
}

/// Every date pair a task gives, each `None` where the file gives none: seconds since
/// 1970-01-01T00:00, no zone (`duration` is in seconds).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TaskTime {
    pub schedule_start: Option<f64>,
    pub schedule_finish: Option<f64>,
    pub early_start: Option<f64>,
    pub early_finish: Option<f64>,
    pub late_start: Option<f64>,
    pub late_finish: Option<f64>,
    pub actual_start: Option<f64>,
    pub actual_finish: Option<f64>,
    pub duration: Option<f64>,
}

impl TaskTime {
    fn from_raw(raw: sys::CadaclysmTaskTime) -> TaskTime {
        TaskTime {
            schedule_start: raw.has_schedule_start.then_some(raw.schedule_start),
            schedule_finish: raw.has_schedule_finish.then_some(raw.schedule_finish),
            early_start: raw.has_early_start.then_some(raw.early_start),
            early_finish: raw.has_early_finish.then_some(raw.early_finish),
            late_start: raw.has_late_start.then_some(raw.late_start),
            late_finish: raw.has_late_finish.then_some(raw.late_finish),
            actual_start: raw.has_actual_start.then_some(raw.actual_start),
            actual_finish: raw.has_actual_finish.then_some(raw.actual_finish),
            duration: raw.has_duration.then_some(raw.duration),
        }
    }
}

/// What one element is doing on a date: [`WorkSchedule::at`]'s rows.
#[derive(Clone, Copy, Debug)]
pub struct ElementState<'s> {
    pub node: Node<'s>,
    pub phase: Phase,
    /// 0..1 through the window that governs the phase.
    pub progress: f64,
    /// Seconds late (positive) or early (negative) against the schedule, `None` where
    /// there is none to give.
    pub variance: Option<f64>,
}

/// A building's programme: an `IfcWorkSchedule` and the tasks it controls. From
/// [`Scene::schedules`]. [`WorkSchedule::at`] says what each element it names is doing on
/// a date; dates are seconds since 1970-01-01T00:00, no zone.
#[derive(Clone)]
pub struct WorkSchedule<'s> {
    scene: &'s Scene,
    pub index: u32,
    /// Its name, else its identification, else `schedule #k`.
    pub name: String,
    /// Its identification, `""` where none.
    pub identification: String,
    pub kind: ScheduleKind,
    /// The text of a user-defined kind ([`ScheduleKind::Other`]); `""` otherwise.
    pub kind_name: String,
    pub start: Option<f64>,
    pub finish: Option<f64>,
}

impl std::fmt::Debug for WorkSchedule<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkSchedule")
            .field("index", &self.index)
            .field("name", &self.name)
            .field("identification", &self.identification)
            .field("kind", &self.kind)
            .field("kind_name", &self.kind_name)
            .field("start", &self.start)
            .field("finish", &self.finish)
            .finish()
    }
}

impl<'s> WorkSchedule<'s> {
    fn task_at(&self, index: u32) -> Task<'s> {
        WorkSchedule::task_of(self.scene, self.index, index)
    }

    fn task_of(owner: &'s Scene, s: u32, index: u32) -> Task<'s> {
        let api = owner.api;
        let scene = owner.raw();
        let mut raw = sys::CadaclysmTaskTime::default();
        unsafe { (api.cadaclysm_task_time)(scene, s, index, &mut raw) };
        Task {
            scene: owner,
            schedule: s,
            index,
            name: unsafe { text((api.cadaclysm_task_name)(scene, s, index)) },
            identification: unsafe { text((api.cadaclysm_task_identification)(scene, s, index)) },
            kind: TaskKind::from_raw(unsafe { (api.cadaclysm_task_kind)(scene, s, index) }),
            kind_name: unsafe { text((api.cadaclysm_task_kind_name)(scene, s, index)) },
            status: unsafe { text((api.cadaclysm_task_status)(scene, s, index)) },
            milestone: unsafe { (api.cadaclysm_task_milestone)(scene, s, index) },
            time: TaskTime::from_raw(raw),
        }
    }

    /// Task `index` (file order), or `None` past the last one -- one task without building
    /// the rest.
    pub fn task(&self, index: usize) -> Option<Task<'s>> {
        let count = unsafe { (self.scene.api.cadaclysm_task_count)(self.scene.raw(), self.index) };
        let index = u32::try_from(index).ok().filter(|&i| i < count)?;
        Some(self.task_at(index))
    }

    /// Its tasks, in file order.
    pub fn tasks(&self) -> Vec<Task<'s>> {
        let count = unsafe { (self.scene.api.cadaclysm_task_count)(self.scene.raw(), self.index) };
        (0..count).map(|i| self.task_at(i)).collect()
    }

    /// Its task links (`IfcRelSequence`), in file order.
    pub fn links(&self) -> Vec<TaskLink<'s>> {
        let api = self.scene.api;
        let count = unsafe { (api.cadaclysm_task_link_count)(self.scene.raw(), self.index) };
        (0..count)
            .filter_map(|l| {
                let (mut from, mut to, mut kind, mut lag, mut has_lag) = (0u32, 0u32, 0u32, 0f64, false);
                let ok = unsafe { (api.cadaclysm_task_link)(self.scene.raw(), self.index, l, &mut from, &mut to, &mut kind, &mut lag, &mut has_lag) };
                ok.then(|| TaskLink {
                    from: self.task_at(from),
                    to: self.task_at(to),
                    kind: LinkKind::from_raw(kind),
                    kind_name: unsafe { text((api.cadaclysm_task_link_kind_name)(self.scene.raw(), self.index, l)) },
                    lag: has_lag.then_some(lag),
                })
            })
            .collect()
    }

    /// What each element this schedule names is doing on `date` (seconds since
    /// 1970-01-01T00:00), in node order; elements no task names are not listed. `dates`
    /// picks which of a task's dates to play. Fails for a `date` that is not finite.
    pub fn at(&self, date: f64, dates: Dates) -> Result<Vec<ElementState<'s>>> {
        let api = self.scene.api;
        let which = match dates {
            Dates::Scheduled => 0,
            Dates::Actual => 1,
        };
        let count = unsafe { (api.cadaclysm_schedule_at)(self.scene.raw(), self.index, date, which, std::ptr::null_mut(), 0) };
        if count < 0 {
            return Err(Error::new(last_error(api)));
        }
        let mut rows = vec![sys::CadaclysmElementState::default(); count as usize];
        unsafe { (api.cadaclysm_schedule_at)(self.scene.raw(), self.index, date, which, rows.as_mut_ptr(), count as u32) };
        Ok(rows
            .into_iter()
            .map(|r| ElementState {
                node: Node { scene: self.scene, index: r.node },
                phase: Phase::from_raw(r.phase),
                progress: r.progress,
                variance: r.has_variance.then_some(r.variance),
            })
            .collect())
    }
}

/// One task of a [`WorkSchedule`]. From [`WorkSchedule::tasks`]; [`Task::parent`] is the
/// summary task nesting it and [`Task::nodes`] the nodes it builds or removes.
#[derive(Clone)]
pub struct Task<'s> {
    scene: &'s Scene,
    schedule: u32,
    pub index: u32,
    pub name: String,
    /// Its identification, `""` where none.
    pub identification: String,
    pub kind: TaskKind,
    /// The text of a user-defined kind ([`TaskKind::Other`]); `""` otherwise.
    pub kind_name: String,
    /// Its status as the file writes it, `""` where none.
    pub status: String,
    pub milestone: bool,
    pub time: TaskTime,
}

// Identity is the triple, so the same task from two lookups is equal.
impl PartialEq for Task<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index && self.schedule == other.schedule && std::ptr::eq(self.scene, other.scene)
    }
}

impl Eq for Task<'_> {}

impl Hash for Task<'_> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.scene as *const Scene).hash(state);
        self.schedule.hash(state);
        self.index.hash(state);
    }
}

impl std::fmt::Debug for Task<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "<Task {} {}>", self.index, self.name)
    }
}

impl<'s> Task<'s> {
    /// The summary task nesting this one, `None` at the top.
    pub fn parent(&self) -> Option<Task<'s>> {
        let mut out = 0u32;
        let found = unsafe { (self.scene.api.cadaclysm_task_parent)(self.scene.raw(), self.schedule, self.index, &mut out) };
        found.then(|| WorkSchedule::task_of(self.scene, self.schedule, out))
    }

    /// The nodes this task builds or removes, sorted, without repeats.
    pub fn nodes(&self) -> Vec<Node<'s>> {
        let api = self.scene.api;
        let count = unsafe { (api.cadaclysm_task_node_count)(self.scene.raw(), self.schedule, self.index) };
        let mut out = vec![0u32; count as usize];
        unsafe { (api.cadaclysm_task_nodes)(self.scene.raw(), self.schedule, self.index, out.as_mut_ptr(), count) };
        out.into_iter().map(|index| Node { scene: self.scene, index }).collect()
    }
}

/// A sequence between two tasks of one schedule (`IfcRelSequence`). From
/// [`WorkSchedule::links`].
#[derive(Clone, Debug)]
pub struct TaskLink<'s> {
    /// The predecessor.
    pub from: Task<'s>,
    /// The successor.
    pub to: Task<'s>,
    pub kind: LinkKind,
    /// The text of a user-defined kind ([`LinkKind::Other`]); `""` otherwise.
    pub kind_name: String,
    /// The time lag in seconds, `None` where the file gives none.
    pub lag: Option<f64>,
}

/// A posed mechanism: [`Scene::pose`], [`Scene::pose_state`] or [`Sequence::pose`]'s answer. The document
/// itself is unchanged.
///
/// Copied eagerly out of the C handle at construction time (see [`copy_pose`]), so a
/// `Pose` holds no C pointer and outlives the call that made it -- closing the scene
/// does not invalidate it. It still borrows the scene, like [`State`], so its [`Link`]s
/// and [`Joint`]s can be compared against ones read from it directly.
#[derive(Clone, Debug)]
pub struct Pose<'s> {
    /// The link held fixed.
    pub ground: Link<'s>,
    /// Joints that close a loop and were not honoured, in file order.
    pub unsolved: Vec<Joint<'s>>,
    /// `(joint, freedom index, value)` for every given value outside its freedom's range.
    pub out_of_range: Vec<(Joint<'s>, u32, f64)>,
    /// What the couplings (gear, rack and pinion, a loop-closing screw) could not solve,
    /// or found disagreeing, in file order, in the kernel's words:
    /// `coupling 'mesh': both 'a' and 'b' are given and disagree by 0.1`.
    pub diagnostics: Vec<String>,
    transforms: Vec<[f64; 16]>,
}

impl<'s> Pose<'s> {
    /// `node`'s posed transform, as rows -- the same shape [`Node::transform`] returns.
    pub fn transform(&self, node: Node<'s>) -> [[f64; 4]; 4] {
        rows(&self.raw_transform(node))
    }

    /// The same matrix in the ABI's own column-major order, exactly as
    /// [`Node::raw_transform`] lays it out.
    pub fn raw_transform(&self, node: Node<'s>) -> [f64; 16] {
        self.transforms[node.index as usize]
    }

    /// Draw this pose's scene with the view library in use, as [`Scene::show`] does -- the
    /// scene by handle -- with every node's posed transform handed to the view
    /// (`cadaclysm_view_set_node_transforms`), which moves each node's geometry by
    /// `raw_transform(n) · n's rest⁻¹`. A node the pose left exactly where it rests takes no
    /// move, so an unposed `Pose` (`scene.pose(&[], None)`) draws exactly what `Scene::show`
    /// does. The library refuses a moved node whose rest transform is singular; that reason
    /// comes back as the `Err`. Same options as `Scene::show`.
    pub fn show<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<()> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        let scene = self.ground.scene();
        scene.shown_with(view::current()?, Shown::Pose(scene, &self.transforms), options, false).map(|_| ())
    }

    /// [`Pose::show`]'s orbiting twin; the same camera [`Scene::view`] returns.
    pub fn view<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<Camera> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        let scene = self.ground.scene();
        scene.shown_with(view::current()?, Shown::Pose(scene, &self.transforms), options, true)?
            .ok_or_else(|| Error::new("view: the view library gave back no camera"))
    }
}

/// Frees a `CadaclysmPose *` even if copying it panics partway through (ruling 2 of the
/// posing plan: wrappers copy eagerly, never holding the C pointer). The Rust analogue
/// of Python's `try`/`finally` around `_copy_pose`.
struct PoseGuard<'a> {
    api: &'a Api,
    ptr: *mut sys::CadaclysmPose,
}

impl Drop for PoseGuard<'_> {
    fn drop(&mut self) {
        unsafe { (self.api.cadaclysm_pose_free)(self.ptr) }
    }
}

/// Reads everything out of a `CadaclysmPose *` into a [`Pose`], then frees it. Shared by
/// [`Scene::pose`] and [`Scene::pose_state`]; `ptr` must not be null.
fn copy_pose(scene: &Scene, ptr: *mut sys::CadaclysmPose) -> Pose<'_> {
    let api = scene.api;
    let guard = PoseGuard { api, ptr };
    let ground = Link { scene, index: unsafe { (api.cadaclysm_pose_ground)(guard.ptr) } };
    let node_count = unsafe { (api.cadaclysm_pose_node_count)(guard.ptr) };
    let transforms = (0..node_count)
        .map(|node| {
            let mut out = [0.0; 16];
            unsafe { (api.cadaclysm_pose_node_transform)(guard.ptr, node, out.as_mut_ptr()) };
            out
        })
        .collect();
    let unsolved_count = unsafe { (api.cadaclysm_pose_unsolved_count)(guard.ptr) };
    let unsolved = (0..unsolved_count)
        .filter_map(|i| {
            let joint = unsafe { (api.cadaclysm_pose_unsolved)(guard.ptr, i) };
            (joint != NONE).then_some(Joint { scene, index: joint })
        })
        .collect();
    let out_of_range_count = unsafe { (api.cadaclysm_pose_out_of_range_count)(guard.ptr) };
    let out_of_range = (0..out_of_range_count)
        .filter_map(|i| {
            let (mut joint, mut freedom, mut value) = (NONE, 0u32, 0.0f64);
            let ok = unsafe { (api.cadaclysm_pose_out_of_range)(guard.ptr, i, &mut joint, &mut freedom, &mut value) };
            ok.then(|| (Joint { scene, index: joint }, freedom, value))
        })
        .collect();
    let diagnostic_count = unsafe { (api.cadaclysm_pose_diagnostic_count)(guard.ptr) };
    let diagnostics = (0..diagnostic_count)
        .filter_map(|i| {
            let raw = unsafe { (api.cadaclysm_pose_diagnostic)(guard.ptr, i) };
            (!raw.is_null()).then(|| unsafe { text(raw) })
        })
        .collect();
    // `guard` drops here, freeing the C pose now that everything is copied.
    Pose { ground, unsolved, out_of_range, diagnostics, transforms }
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

    /// Draw this node with the view library in use: its scene by handle, everything outside
    /// this node hidden, fitted to it. Options as [`Scene::show`].
    pub fn show<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<()> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        self.scene.shown_with(view::current()?, Shown::Node(*self), options, false).map(|_| ())
    }

    /// Orbit this node until the window is closed; where the camera was left.
    pub fn view<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<Camera> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        self.scene.shown_with(view::current()?, Shown::Node(*self), options, true)?.ok_or_else(|| Error::new("view: the view library gave back no camera"))
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
    ///
    /// The library lends the text from one slot per scene, shared with [`Scene::svg_text`] and
    /// replaced by the next call of either; this holds the scene's `svg_text` lock for the call
    /// and the copy, so the slot is serialised and two threads cannot free each other's text.
    /// `the_svg_text_calls_wait_for_the_scenes_lock` witnesses that it waits for that lock.
    pub fn svg_text<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<String> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let api = self.scene.api;
        let raw = build_svg_options(api, options, self.scene.default_up())?;
        let _slot = self.scene.svg_text.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let ptr = unsafe { (api.cadaclysm_node_svg_text)(self.scene.raw(), self.index, &raw) };
        if ptr.is_null() {
            let reason = last_error(api);
            return Err(Error::new(if reason.is_empty() { "svg".to_string() } else { reason }));
        }
        Ok(unsafe { text(ptr) })
    }

    /// This node's silhouette -- where its surfaces turn away from the eye, which no edge of it
    /// lies on -- as rational cubic Béziers in `double`, from the camera `options` describes
    /// (`None` for [`SvgOptions::default`]). The same [`SvgOptions`] that draw a picture:
    /// `view`, `azimuth`, `elevation`, `up` and `fov`, and `width` with `tolerance`, which the
    /// library reads together as the page fraction `tolerance / width`. Nothing else in them
    /// changes the curves.
    ///
    /// Unlike [`Node::edge_beziers64`] this is a copy, not a borrow. The library keeps one
    /// silhouette slot per scene and the next silhouette call on that scene, for any node,
    /// replaces it, so a `&[f64]` into it would change under a caller who asked twice. This copies
    /// out of the slot before it returns, holding a lock on the scene for the call and the copy
    /// because the library says two threads calling it free each other's arrays.
    ///
    /// A body with no silhouette (every face planar) is an empty answer, not an error; a refused
    /// option, a body with no measurable geometry or a node holding no shape of its own is an
    /// `Err`.
    pub fn silhouette_beziers<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<Beziers64Data> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let api = self.scene.api;
        let raw = build_svg_options(api, options, self.scene.default_up())?;
        let _slot = self.scene.silhouette.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let got = unsafe { (api.cadaclysm_node_silhouette_beziers)(self.scene.raw(), self.index, &raw) };
        if got.count == 0 || got.points.is_null() {
            // The library clears the thread's error at entry and the empty answer sets none: a
            // reason here is this call's own refusal, none is the empty answer.
            let reason = last_error(api);
            if reason.is_empty() {
                return Ok(Beziers64Data::default());
            }
            return Err(Error::new(reason));
        }
        Ok(Beziers64::from_raw(got).copy())
    }

    /// [`Node::svg_text`] written to `path` by the library itself.
    pub fn svg<'o>(&self, path: impl AsRef<Path>, options: impl Into<Option<&'o SvgOptions>>) -> Result<()> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let path = path.as_ref();
        let c_path = c_path(path)?;
        let api = self.scene.api;
        let raw = build_svg_options(api, options, self.scene.default_up())?;
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
/// `cadaclysm_view.VIEWS` gives Python's `show()` and `svg()` both. Degrees
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
    /// The pen colour, an [`SvgColour`]: `"navy".into()`, `"#000080".into()` or
    /// `0x00_0080.into()`. Default black.
    pub stroke: SvgColour,
    /// The pen's width, page units. Default 1.
    pub stroke_width: f64,
    /// An [`SvgColour`] -- `Some("navy".into())` or `Some(0x00_0080.into())` -- or `None`
    /// (the default) for no `<rect>` behind the drawing -- the page left to whatever the
    /// viewer composites it onto.
    pub background: Option<SvgColour>,
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
    /// Also draw each body's silhouettes -- where its surfaces turn away from the eye,
    /// which no edge lies on, so a sphere gains an outline it otherwise has none of.
    /// One group per body, after that body's lines. Default `true`.
    ///
    /// On by default because a line set alone cannot draw every body: a sphere is one
    /// face closed on itself and a torus one closed on itself twice, so each body's only
    /// curves are the seams where that face meets itself -- not edges of the body, and
    /// never drawn -- and without this those two draw a blank page. A line set in its own
    /// right: set it with `edges` false for an outline-only drawing, or clear it for the
    /// lines alone. Only naming nothing at all is refused.
    pub silhouettes: bool,
}

impl Default for SvgOptions {
    /// The defaults `cadaclysm_svg_options_init` fills: the viewer's iso, orthographic,
    /// a 1000-square page, black edges one unit wide on nothing, and each body's
    /// outline beside them.
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
            stroke: SvgColour::Packed(0x00_0000),
            stroke_width: 1.0,
            background: None,
            edges: true,
            curves: false,
            isocurves: false,
            polylines: false,
            silhouettes: true,
        }
    }
}

/// `CadaclysmSvgOptions::background`'s "none" value -- `CADACLYSM_SVG_TRANSPARENT`, the
/// same on both headers.
const SVG_TRANSPARENT: u32 = 0xFFFF_FFFF;

/// `options` packed into a `CadaclysmSvgOptions`: `view` fills `azimuth`/`elevation`
/// unless they are set directly, `up` falls back to `default_up`. `cadaclysm_svg_options_init`
/// fills the struct first -- `size` included -- so a field this crate never sets still
/// carries the library's own default rather than a zeroed struct's. An [`Error`] where
/// `stroke` or `background` is colour text the library refuses.
fn build_svg_options(api: &Api, options: &SvgOptions, default_up: Up) -> Result<sys::CadaclysmSvgOptions> {
    let stroke = options.stroke.packed_with("svg: stroke", parse_colour)?;
    let background = match &options.background {
        Some(colour) => colour.packed_with("svg: background", parse_colour)?,
        None => SVG_TRANSPARENT,
    };
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
    raw.stroke = stroke;
    raw.background = background;
    raw.flags = u32::from(options.edges)
        | (u32::from(options.curves) << 1)
        | (u32::from(options.isocurves) << 2)
        | (u32::from(options.polylines) << 3)
        | (u32::from(options.silhouettes) << 4);
    Ok(raw)
}

// ---- the scene --------------------------------------------------------------------

/// An open document, closed when dropped. Everything it hands back borrows from it.
pub struct Scene {
    handle: NonNull<sys::CadaclysmScene>,
    api: &'static Api,
    path: PathBuf,
    schema_path: Option<PathBuf>,
    convention: u32,
    /// Held across a silhouette call and the copy out of the slot it fills: the library keeps one
    /// slot per scene and says two threads calling it free each other's arrays, while a `Scene`
    /// is `Sync`.
    silhouette: Mutex<()>,
    /// Held across an `svg_text` call and the copy out of the text it returns, by both
    /// [`Scene::svg_text`] and [`Node::svg_text`]: they share one per-scene slot in the library,
    /// `svg_text: Mutex<Option<CString>>`, and that mutex guards the slot's REPLACEMENT, not a
    /// caller's read of the `CString` it lends, so a second thread's call could free the text the
    /// first is still copying. A lock of its own, not `silhouette`'s, so the two slots do not
    /// contend. `the_svg_text_calls_wait_for_the_scenes_lock` witnesses that both methods take it:
    /// with the test thread holding this lock, neither completes until it is released. (The
    /// silhouette lock above has its own twin, `the_silhouette_call_waits_for_the_scenes_lock`; it
    /// does not witness this one.)
    svg_text: Mutex<()>,
}

// The ABI's accessors take a `const` handle and the library asserts its scene is `Sync` at
// compile time, and closing takes `self`. That is not a promise that every accessor is safe to
// call from two threads at once: `Node::silhouette_beziers` takes the `silhouette` lock above
// for exactly that reason, and the two `svg_text` methods take the `svg_text` lock above for the
// same one (the library lends their text from one per-scene slot too). This comment says nothing
// about the others.
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

    /// The file's named mechanism states -- see [`State`]. Empty where the file names
    /// none.
    pub fn states(&self) -> Vec<State<'_>> {
        let api = self.api;
        let count = unsafe { (api.cadaclysm_state_count)(self.raw()) };
        (0..count)
            .map(|index| {
                let name = unsafe { text((api.cadaclysm_state_name)(self.raw(), index)) };
                let rows = unsafe { (api.cadaclysm_state_value_count)(self.raw(), index) };
                let values = (0..rows)
                    .filter_map(|row| {
                        let mut joint: u32 = sys::CADACLYSM_NONE;
                        let n = unsafe { (api.cadaclysm_state_value)(self.raw(), index, row, &mut joint, std::ptr::null_mut(), 0) };
                        if joint == sys::CADACLYSM_NONE {
                            return None;
                        }
                        let mut values = vec![0.0; n as usize];
                        unsafe { (api.cadaclysm_state_value)(self.raw(), index, row, &mut joint, values.as_mut_ptr(), n) };
                        Some(StateValue { joint: Joint { scene: self, index: joint }, values })
                    })
                    .collect();
                State { index, name, values }
            })
            .collect()
    }

    /// The file's motion sequences -- see [`Sequence`]. Empty where the file records none.
    pub fn sequences(&self) -> Vec<Sequence<'_>> {
        let api = self.api;
        let states = self.states();
        let count = unsafe { (api.cadaclysm_sequence_count)(self.raw()) };
        (0..count)
            .map(|index| {
                let name = unsafe { text((api.cadaclysm_sequence_name)(self.raw(), index)) };
                let closed = unsafe { (api.cadaclysm_sequence_closed)(self.raw(), index) };
                let seconds = unsafe { (api.cadaclysm_sequence_seconds_per_unit)(self.raw(), index) };
                let n = unsafe { (api.cadaclysm_sequence_segment_count)(self.raw(), index) };
                let segments = (0..n)
                    .filter_map(|i| {
                        let (mut state, mut t, mut interpolation) = (0u32, 0f64, 0u32);
                        let ok = unsafe { (api.cadaclysm_sequence_segment)(self.raw(), index, i, &mut state, &mut t, &mut interpolation) };
                        let state = states.get(state as usize)?.clone();
                        ok.then(|| Segment { state, t, interpolation: Interpolation::from_raw(interpolation) })
                    })
                    .collect();
                Sequence { scene: self, index, name, closed, seconds_per_unit: (seconds != 0.0).then_some(seconds), segments }
            })
            .collect()
    }

    /// The file's work schedules -- see [`WorkSchedule`]. Empty where the file records none.
    pub fn schedules(&self) -> Vec<WorkSchedule<'_>> {
        let count = unsafe { (self.api.cadaclysm_schedule_count)(self.raw()) };
        (0..count).map(|index| self.schedule_of(index)).collect()
    }

    /// Work schedule `index` (file order), or `None` past the last one -- one schedule
    /// without building the rest.
    pub fn schedule(&self, index: usize) -> Option<WorkSchedule<'_>> {
        let count = unsafe { (self.api.cadaclysm_schedule_count)(self.raw()) };
        let index = u32::try_from(index).ok().filter(|&i| i < count)?;
        Some(self.schedule_of(index))
    }

    fn schedule_of(&self, index: u32) -> WorkSchedule<'_> {
        let api = self.api;
        let mut start = 0f64;
        let mut finish = 0f64;
        let has_start = unsafe { (api.cadaclysm_schedule_start)(self.raw(), index, &mut start) };
        let has_finish = unsafe { (api.cadaclysm_schedule_finish)(self.raw(), index, &mut finish) };
        WorkSchedule {
            scene: self,
            index,
            name: unsafe { text((api.cadaclysm_schedule_name)(self.raw(), index)) },
            identification: unsafe { text((api.cadaclysm_schedule_identification)(self.raw(), index)) },
            kind: ScheduleKind::from_raw(unsafe { (api.cadaclysm_schedule_kind)(self.raw(), index) }),
            kind_name: unsafe { text((api.cadaclysm_schedule_kind_name)(self.raw(), index)) },
            start: has_start.then_some(start),
            finish: has_finish.then_some(finish),
        }
    }

    /// The link the file declares as the mechanism's base, or `None` when it declares
    /// none (the default ground is then the link on the most joints; see [`Scene::pose`]).
    pub fn base(&self) -> Option<Link<'_>> {
        let index = unsafe { (self.api.cadaclysm_kinematics_base)(self.raw()) };
        (index != NONE).then_some(Link { scene: self, index })
    }

    /// The mechanism posed by `values`: one row per joint to set, naming the joint and
    /// giving one value per freedom of its pair -- exactly [`State::values`]' row type,
    /// so `pose(&state.values, ground)` poses like `pose_state(state, ground)` -- with
    /// `ground` (a [`Link`], or `None` for the default ground) held fixed. Values
    /// outside a freedom's range are used as given and reported in the answer's
    /// `out_of_range`.
    ///
    /// Fails on a bad row (a joint given twice, one with the wrong number of values,
    /// ...) or a file with no mechanism, carrying the library's own message unchanged.
    pub fn pose(&self, values: &[StateValue<'_>], ground: Option<Link<'_>>) -> Result<Pose<'_>> {
        let joints: Vec<u32> = values.iter().map(|row| row.joint.index).collect();
        let counts: Vec<u32> = values.iter().map(|row| row.values.len() as u32).collect();
        let flat: Vec<f64> = values.iter().flat_map(|row| row.values.iter().copied()).collect();
        let ground_index = ground.map_or(NONE, |link| link.index);
        let api = self.api;
        let ptr = unsafe {
            (api.cadaclysm_pose)(
                self.raw(),
                joints.as_ptr(),
                counts.as_ptr(),
                flat.as_ptr(),
                values.len() as u32,
                ground_index
            )
        };
        if ptr.is_null() {
            return Err(Error::new(last_error(api)));
        }
        Ok(copy_pose(self, ptr))
    }

    /// The mechanism posed by `state`'s values, with `ground` held fixed as
    /// [`Scene::pose`] does. Fails as [`Scene::pose`] does.
    pub fn pose_state(&self, state: &State<'_>, ground: Option<Link<'_>>) -> Result<Pose<'_>> {
        let ground_index = ground.map_or(NONE, |link| link.index);
        let api = self.api;
        let ptr = unsafe { (api.cadaclysm_pose_state)(self.raw(), state.index, ground_index) };
        if ptr.is_null() {
            return Err(Error::new(last_error(api)));
        }
        Ok(copy_pose(self, ptr))
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

    /// Draw the document with the view library in use ([`view::current`]), by handle --
    /// every visible placement where the file puts it. On the terminal, one still in the
    /// scrollback; on the wgpu library ([`view::use_wgpu`]), a window that this call waits
    /// on until it is closed. `options.up` defaults to this scene's convention;
    /// `options.edges` switches the edges layer; `options.tolerance` must be `None` -- a
    /// document is drawn at the tolerance it was read with.
    pub fn show<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<()> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        self.shown_with(view::current()?, Shown::Scene(self), options, false).map(|_| ())
    }

    /// Orbit the model until the window is closed; where the camera was left.
    pub fn view<'o>(&self, options: impl Into<Option<&'o ViewOptions>>) -> Result<Camera> {
        let default = ViewOptions::default();
        let options = options.into().unwrap_or(&default);
        Scene::check_tolerance(options)?;
        self.shown_with(view::current()?, Shown::Scene(self), options, true)?.ok_or_else(|| Error::new("view: the view library gave back no camera"))
    }

    /// `options.tolerance` must be `None` for any `show`/`view` on a document already read at
    /// its own tolerance (`Scene`/`Node`/`Pose`) -- checked before [`view::current`] loads a
    /// library, so a missing library never masks this refusal.
    fn check_tolerance(options: &ViewOptions) -> Result<()> {
        if options.tolerance.is_some() {
            return Err(Error::new("a document is drawn at the tolerance it was read with: leave ViewOptions::tolerance None"));
        }
        Ok(())
    }

    /// `shown` (this scene, or one of its nodes) with `library`, titled by the file's name.
    fn shown_with(&self, library: &'static view::Library, shown: Shown<'_>, options: &ViewOptions, orbit: bool) -> Result<Option<Camera>> {
        Scene::check_tolerance(options)?;
        let name = self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        present(library, shown, options, &name, SvgView::Iso, self.default_up(), orbit)
    }

    /// Every visible placement's wireframe as SVG text, from the camera `options`
    /// describes -- the library's own camera, not a viewer. See [`SvgOptions`].
    /// Borrowed by the library: copied out before this returns, and replaced by this
    /// scene's next `svg_text` call, on the scene or on any of its nodes (`svg` writes straight to
    /// a file and leaves the slot alone).
    ///
    /// The slot is serialised: this holds the scene's `svg_text` lock (the one [`Node::svg_text`]
    /// takes too) for the call and the copy, so two threads cannot free each other's text.
    /// `the_svg_text_calls_wait_for_the_scenes_lock` witnesses that both methods wait for it.
    pub fn svg_text<'o>(&self, options: impl Into<Option<&'o SvgOptions>>) -> Result<String> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let api = self.api;
        let raw = build_svg_options(api, options, self.default_up())?;
        let _slot = self.svg_text.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let ptr = unsafe { (api.cadaclysm_scene_svg_text)(self.raw(), &raw) };
        if ptr.is_null() {
            let reason = last_error(api);
            return Err(Error::new(if reason.is_empty() { "svg".to_string() } else { reason }));
        }
        Ok(unsafe { text(ptr) })
    }

    /// [`Scene::svg_text`] written to `path` by the library itself.
    pub fn svg<'o>(&self, path: impl AsRef<Path>, options: impl Into<Option<&'o SvgOptions>>) -> Result<()> {
        let default = SvgOptions::default();
        let options = options.into().unwrap_or(&default);
        let path = path.as_ref();
        let c_path = c_path(path)?;
        let api = self.api;
        let raw = build_svg_options(api, options, self.default_up())?;
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
            Some(handle) => Ok(Scene { handle, api, path, schema_path: self.schema.clone(), convention: self.convention, silhouette: Mutex::new(()), svg_text: Mutex::new(()) }),
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

    /// Open a CAD file. A `.zip` (or `.stpZ`, STEP's zip) opens its first readable member;
    /// [`Scene::source_name`] says which. A `.gz` is read as the format named before it:
    /// `part.step.gz` as `.step`. An unrecognised convention is an error, never read as `Native`.
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

    /// Needs the real library (`CADACLYSM_LIBRARY`); skips quietly without one, like this
    /// module's other library-needing tests. The skip check is `version()`, not `packed`
    /// itself: a `packed` that always errs must not be able to hide behind that skip.
    #[test]
    fn packed_reads_css_names_through_the_library() {
        if let Err(err) = version() {
            eprintln!("skipped: {err} (no library to read colour names with)");
            return;
        }
        assert_eq!(packed("navy").unwrap(), 0x00_00_80);
        let err = packed("bogus").unwrap_err().to_string();
        assert!(err.contains("not 'bogus'"), "{err}");
        assert!(!err.contains("0..1"), "{err}");
    }

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

    /// [`PairKind::from_raw`] and [`Freedom::from_raw`] are pure -- no library needed --
    /// so this pins them field for field, the way the FEM test above pins its structs:
    /// a bounded freedom, an unbounded one, and every unnamed pair kind (`-1` for "no
    /// pair", and anything past `12`) as `None`.
    #[test]
    fn a_pair_kind_and_freedom_are_read_field_for_field() {
        assert_eq!(PairKind::from_raw(0), Some(PairKind::Revolute));
        assert_eq!(PairKind::from_raw(8), Some(PairKind::Screw));
        assert_eq!(PairKind::from_raw(12), Some(PairKind::Other));
        assert_eq!(PairKind::from_raw(-1), None);
        assert_eq!(PairKind::from_raw(13), None);

        let bounded = sys::CadaclysmFreedom { motion: 0, axis: 2, has_lower: true, lower: -1.5, has_upper: true, upper: 1.5 };
        let bounded = Freedom::from_raw(bounded);
        assert_eq!(bounded, Freedom { motion: Motion::Rotation, axis: FreedomAxis::Z, lower: Some(-1.5), upper: Some(1.5) });

        let unbounded = sys::CadaclysmFreedom { motion: 1, axis: 1, has_lower: false, lower: 0.0, has_upper: false, upper: 0.0 };
        let unbounded = Freedom::from_raw(unbounded);
        assert_eq!(unbounded, Freedom { motion: Motion::Translation, axis: FreedomAxis::Y, lower: None, upper: None });

        // The header's own size (`bool` fields are one byte each in C, as Rust's are;
        // each is followed by padding out to the next `f64`'s 8-byte alignment).
        assert_eq!(std::mem::size_of::<sys::CadaclysmFreedom>(), 40);
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

    use std::collections::HashSet;

    use crate::view::{fake, objects::Shown, ViewOptions};

    /// Two cubes, the second three units along x -- two placements, each a mesh.
    /// `tag` gives each test its own scratch path: `cargo test` runs tests on parallel
    /// threads, and a shared fixed path lets one thread's write race another's open.
    fn two_cubes(tag: &str) -> Option<Scene> {
        let path = std::env::temp_dir().join(format!("cadaclysm-rust-viewer-two-cubes-{tag}.scad"));
        if std::fs::write(&path, "cube(1); translate([3, 0, 0]) cube(1);").is_err() {
            eprintln!("skipped: could not write a scratch .scad file");
            return None;
        }
        match open(&path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the cubes with)");
                None
            }
        }
    }

    #[test]
    fn a_scene_refuses_a_tolerance() {
        let Some(scene) = two_cubes("tolerance") else { return };
        let err = scene.show(&ViewOptions { tolerance: Some(0.1), ..ViewOptions::default() }).unwrap_err();
        assert!(err.message().contains("tolerance"), "{}", err.message());
    }

    /// The tolerance refusal must reach the caller even with no view library to be found at
    /// all -- `show`/`view` check `options.tolerance` before `view::current()` loads
    /// anything, so a missing library never masks it behind "no view library". Run in a
    /// child process (as `view::tests::draws_in_a_child`'s caller does) so this process's
    /// own cached `view::current()` library (other tests may have loaded one already, under
    /// `view::CURRENT_LOCK`) and other tests running in parallel cannot interfere with the
    /// child's `CADACLYSM_TERMINAL_LIBRARY`.
    #[test]
    fn a_scene_checks_tolerance_before_loading_a_view_library() {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["tests::tolerance_checked_before_view_library_in_a_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env("CADACLYSM_TERMINAL_LIBRARY", "/does/not/exist/cadaclysm_terminal_missing")
            .env_remove("CADACLYSM_VIEW")
            .output()
            .expect("the test binary runs again");
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "the child failed: {stdout}\n{}", String::from_utf8_lossy(&out.stderr));
        if stdout.contains("MESSAGE: SKIP") {
            eprintln!("skipped: {stdout} (no library to open the cubes with, in the child)");
            return;
        }
        // `--nocapture` interleaves this print with cargo's own "test ... " progress line (no
        // leading newline before the test finishes), so the marker can land mid-line: search
        // the whole capture for it rather than matching a line's prefix.
        let message = stdout
            .split("MESSAGE: ")
            .nth(1)
            .map(|rest| rest.lines().next().unwrap_or(rest))
            .unwrap_or_else(|| panic!("no MESSAGE marker: {stdout:?}"));
        assert!(message.contains("tolerance"), "{message}");
        assert!(!message.contains("no view library"), "the missing library masked the tolerance refusal: {message}");
    }

    #[test]
    #[ignore = "run by a_scene_checks_tolerance_before_loading_a_view_library, in a child process"]
    fn tolerance_checked_before_view_library_in_a_child() {
        if std::env::var_os("CADACLYSM_TERMINAL_LIBRARY").is_none() {
            return;
        }
        let Some(scene) = two_cubes("tolerance-child") else {
            println!("MESSAGE: SKIP");
            return;
        };
        let err = scene.show(&ViewOptions { tolerance: Some(0.1), ..ViewOptions::default() }).unwrap_err();
        println!("MESSAGE: {}", err.message());
    }

    #[test]
    fn a_scene_is_shown_by_its_handle() {
        let Some(scene) = two_cubes("handle") else { return };
        let view = crate::view::View::open(fake::leaked(), crate::view::target_own(), &ViewOptions::default(), "part", Up::Z).unwrap();
        fake::take();
        assert_eq!(view.show_scene(&scene).unwrap().id(), 21);
        assert_eq!(fake::take(), ["show scene"]);
    }

    #[test]
    fn a_node_hides_what_is_outside_it_by_handle() {
        // `two_cubes`' OpenSCAD scene has two top-level cubes, both roots with no
        // children (OpenSCAD's own reader never nests), so this needs real assembly
        // depth: `mechanism-solid.stp`'s `arm` (bracket, plate, bolt), the bracket
        // itself holding a plate and two bolts -- a node whose parent is not a root.
        let Some(scene) = open_mechanism_solid() else { return };
        let Some(one) = scene.walk().find(|n| n.parent().is_some() && n.children().is_empty()) else {
            eprintln!("skipped: the mechanism's scene has no leaf below a root");
            return;
        };
        // What must be hidden: every node outside `one`'s subtree and ancestors whose parent
        // is an ancestor (or which is a root) -- hiding it hides the rest.
        let mut ancestors = HashSet::new();
        let mut at = one.parent();
        while let Some(node) = at {
            ancestors.insert(node.index());
            at = node.parent();
        }
        let mut expected: Vec<String> = scene
            .walk()
            .filter(|n| n.index() != one.index() && !ancestors.contains(&n.index()))
            .filter(|n| n.parent().map_or(true, |p| ancestors.contains(&p.index())))
            .map(|n| format!("node_visible 21 {} false", n.index()))
            .collect();
        assert!(!expected.is_empty(), "the mechanism: siblings outside the node are hidden");
        let view = crate::view::View::open(fake::leaked(), crate::view::target_own(), &ViewOptions::default(), "part", Up::Z).unwrap();
        fake::take();
        view.show_node(one).unwrap();
        let mut log = fake::take();
        assert_eq!(log.remove(0), "show scene");
        log.sort();
        expected.sort();
        assert_eq!(log, expected);
    }

    #[test]
    fn a_scene_shows_itself_by_handle_titled_by_its_file() {
        let Some(scene) = two_cubes("show") else { return };
        fake::take();
        scene.shown_with(fake::leaked(), Shown::Scene(&scene), &ViewOptions { edges: false, ..ViewOptions::default() }, false).unwrap();
        let log = fake::take();
        assert!(log[0].starts_with("create cadaclysm-rust-viewer-two-cubes-show.scad "), "{log:?}");
        assert_eq!(log[1], "show scene");
        assert!(log.iter().any(|l| l == "layer 1 false"), "{log:?}");
        assert!(log.iter().any(|l| l == "frame 0"), "{log:?}");
    }

    #[test]
    fn a_node_shows_its_scene_fitted_to_itself() {
        let Some(scene) = open_mechanism_solid() else { return };
        let one = scene
            .walk()
            .find(|n| n.parent().is_some())
            .expect("the mechanism's scene has a node below a root");
        fake::take();
        scene.shown_with(fake::leaked(), Shown::Node(one), &ViewOptions::default(), false).unwrap();
        let log = fake::take();
        // F14: aim always frames everything first (Python's `_aim` calls `frame(0)`
        // unconditionally), then fits the node on top of it with its own `frame_node`.
        let frame_at = log.iter().position(|l| l == "frame 0").expect(&format!("{log:?}"));
        let frame_node_at = log
            .iter()
            .position(|l| *l == format!("frame_node 21 {}", one.index()))
            .expect(&format!("{log:?}"));
        assert!(frame_at < frame_node_at, "frame everything, then fit the node: {log:?}");
    }

    /// Review round 1, F-aim: `aim`'s `item.frame_node` refusal must reach `present`'s
    /// caller as its own `Err` (Python's `Item.frame_node` raises through `_ok`), not be
    /// swallowed the way `standard`/`orbit`/`frame`/`zoom` are. `mechanism-solid.stp` (not
    /// `two_cubes`) is used here since it is guaranteed to have a node below a root.
    #[test]
    fn a_refused_frame_node_is_the_error_and_the_view_is_destroyed() {
        let Some(scene) = open_mechanism_solid() else { return };
        let Some(one) = scene.walk().find(|n| n.parent().is_some() && n.children().is_empty()) else {
            eprintln!("skipped: the mechanism's scene has no leaf below a root");
            return;
        };
        fake::take();
        fake::fail_at("frame_node");
        let err = scene.shown_with(fake::leaked(), Shown::Node(one), &ViewOptions::default(), false).unwrap_err();
        fake::fail_at("");
        assert_eq!(err.message(), "fake 1.0: fake failure");
        assert_eq!(fake::take().last().map(String::as_str), Some("destroy"));
    }

    // ---- Pose::show / Pose::view (mechanism playback) ------------------------------

    /// `samples/mechanism.stp`, beside this repository's root -- the same file
    /// `mechanism_checks` in `examples/smoke.rs` poses. Carries kinematics but no mesh
    /// geometry at all (its two parts' shape representations hold only an axis
    /// placement, no solid): `Scene::placements` is empty for it, so it proves nothing
    /// by itself about what gets drawn -- see `open_mechanism_solid`. Skips quietly
    /// without a library, like `two_cubes`.
    fn open_mechanism() -> Option<Scene> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../samples/mechanism.stp");
        match open(path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the mechanism with)");
                None
            }
        }
    }

    /// The same shape of mechanism as `open_mechanism`, but with real geometry:
    /// `samples/mechanism-solid.stp`, generated by `samples/mechanism-solid.py` (that
    /// script's own docstring says how, and that the file is pinned -- edit the script
    /// and regenerate by hand to change it). A plate and two bolts (links `fixed`/
    /// `bolts`, joined by a prismatic `screw`) nested inside an `arm` assembly beside a
    /// base plate and a third bolt (links `ground`/`upper arm`, joined by a revolute
    /// `shoulder`), two states `reach` and `rest` and the sequence `lift`. Skips quietly without a library.
    fn open_mechanism_solid() -> Option<Scene> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../samples/mechanism-solid.stp");
        match open(path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the mechanism with)");
                None
            }
        }
    }

    fn sequenced() -> Option<Scene> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../samples/mechanism-sequence.stp");
        match open(path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the sequenced mechanism with)");
                None
            }
        }
    }

    #[test]
    fn a_file_reads_its_motion_sequences() {
        let Some(scene) = sequenced() else { return };
        let sequences = scene.sequences();
        assert_eq!(sequences.len(), 2);
        let swing = &sequences[0];
        assert_eq!((swing.name.as_str(), swing.closed, swing.seconds_per_unit), ("swing", true, Some(1.0)));
        let got: Vec<(&str, f64, Interpolation)> = swing.segments.iter().map(|s| (s.state.name.as_str(), s.t, s.interpolation)).collect();
        assert_eq!(got, [("shut", 0.0, Interpolation::Linear), ("open", 1.0, Interpolation::Synchronous), ("wide", 2.0, Interpolation::Linear)]);
        assert_eq!((swing.start(), swing.end()), (0.0, 2.0));
        assert_eq!(sequences[1].seconds_per_unit, None);
        assert_eq!(Interpolation::Discontinuous.name(), "discontinuous");
    }

    #[test]
    fn a_sequence_poses_like_its_state_at_a_segment() {
        let Some(scene) = sequenced() else { return };
        let swing = &scene.sequences()[0];
        for segment in &swing.segments {
            let by_sequence = swing.pose(segment.t, None).unwrap();
            let by_state = scene.pose_state(&segment.state, None).unwrap();
            for node in scene.walk() {
                assert_eq!(by_sequence.raw_transform(node), by_state.raw_transform(node));
            }
        }
        assert_eq!(swing.pose(f64::NAN, None).unwrap_err().to_string(), "the sequence parameter must be a finite number");
    }

    const DAY: f64 = 86400.0;
    const T0: f64 = 1772438400.0;

    /// `samples/schedule.ifc`: one programme, seven tasks. Skips quietly without a library.
    fn scheduled() -> Option<Scene> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../samples/schedule.ifc");
        match open(path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library to open the schedule with)");
                None
            }
        }
    }

    #[test]
    fn schedule_a_file_reads_its_programme() {
        let Some(scene) = scheduled() else { return };
        let schedules = scene.schedules();
        assert_eq!(schedules.len(), 1);
        let s = &schedules[0];
        assert_eq!(
            (s.name.as_str(), s.identification.as_str(), s.kind, s.kind_name.as_str(), s.start, s.finish),
            ("Programme", "WS-1", ScheduleKind::Planned, "", Some(T0), None)
        );
        assert_eq!(s.kind.name(), "planned");
    }

    #[test]
    fn schedule_tasks_come_in_order_with_their_parents_kinds_and_dates() {
        let Some(scene) = scheduled() else { return };
        let s = &scene.schedules()[0];
        let tasks = s.tasks();
        let names: Vec<&str> = tasks.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["Slab", "Structure", "Walls north", "Walls south", "Topping out", "Demolish shed", "Fit-out"]);
        let (slab, structure, north, south, topping, shed) = (&tasks[0], &tasks[1], &tasks[2], &tasks[3], &tasks[4], &tasks[5]);
        assert_eq!((north.parent().as_ref(), south.parent().as_ref(), slab.parent()), (Some(structure), Some(structure), None));
        assert_eq!((slab.kind, shed.kind, topping.kind), (TaskKind::Construction, TaskKind::Demolition, TaskKind::NotDefined));
        assert_eq!(slab.kind.name(), "construction");
        assert!(topping.milestone && !slab.milestone);
        assert_eq!((slab.identification.as_str(), slab.status.as_str()), ("T1", "COMPLETED"));
        assert_eq!((slab.time.schedule_start, slab.time.schedule_finish, slab.time.duration), (Some(T0), None, Some(10.0 * DAY)));
        assert_eq!((slab.time.actual_start, slab.time.actual_finish), (Some(T0), Some(T0 + 8.0 * DAY)));
    }

    #[test]
    fn schedule_and_task_by_index_match_the_lists_and_stop_at_the_end() {
        let Some(scene) = scheduled() else { return };
        let s = scene.schedule(0).expect("schedule 0");
        assert_eq!(s.name, scene.schedules()[0].name);
        assert!(scene.schedule(1).is_none() && scene.schedule(usize::MAX).is_none());
        let tasks = s.tasks();
        assert_eq!(s.task(1).expect("task 1").name, tasks[1].name);
        assert!(s.task(tasks.len()).is_none() && s.task(usize::MAX).is_none());
    }

    #[test]
    fn schedule_tasks_name_their_nodes() {
        let Some(scene) = scheduled() else { return };
        let tasks = scene.schedules()[0].tasks();
        let names = |t: &Task| {
            let mut names: Vec<String> = t.nodes().iter().map(|n| n.name()).collect();
            names.sort();
            names
        };
        assert_eq!(names(&tasks[3]), ["Wall S1", "Wall S2"]);
        assert_eq!(names(&tasks[6]), ["Desk", "Room"]);
    }

    #[test]
    fn schedule_links_run_between_tasks() {
        let Some(scene) = scheduled() else { return };
        let links = scene.schedules()[0].links();
        let got: Vec<(String, String, LinkKind, Option<f64>)> =
            links.iter().map(|l| (l.from.name.clone(), l.to.name.clone(), l.kind, l.lag)).collect();
        let want = |a: &str, b: &str, k, lag| (a.to_string(), b.to_string(), k, lag);
        assert_eq!(
            got,
            [
                want("Slab", "Structure", LinkKind::FinishStart, None),
                want("Walls north", "Walls south", LinkKind::StartStart, Some(2.0 * DAY)),
                want("Walls south", "Topping out", LinkKind::FinishStart, None),
                want("Topping out", "Fit-out", LinkKind::FinishStart, None),
            ]
        );
        assert_eq!(links[0].kind_name, "");
        assert_eq!(LinkKind::StartStart.name(), "start_start");
    }

    #[test]
    fn schedule_says_what_each_element_is_doing() {
        let Some(scene) = scheduled() else { return };
        let s = &scene.schedules()[0];
        let states: std::collections::HashMap<String, ElementState> =
            s.at(T0 + 3.0 * DAY, Dates::Scheduled).unwrap().into_iter().map(|e| (e.node.name(), e)).collect();
        let mut names: Vec<&str> = states.keys().map(String::as_str).collect();
        names.sort();
        assert_eq!(names, ["Desk", "Room", "Shed", "Slab", "Wall N1", "Wall N2", "Wall S1", "Wall S2"]);
        assert_eq!(states["Slab"].phase, Phase::Building);
        assert!((states["Slab"].progress - 0.3).abs() < 1e-9);
        assert_eq!(states["Shed"].phase, Phase::Demolishing);
        assert_eq!(states["Wall S1"].phase, Phase::Unbuilt);
        assert_eq!(Phase::Demolished.name(), "demolished");

        let late: std::collections::HashMap<String, ElementState> =
            s.at(T0 + 32.0 * DAY, Dates::Actual).unwrap().into_iter().map(|e| (e.node.name(), e)).collect();
        assert_eq!(late["Wall S1"].phase, Phase::Building);
        assert_eq!(late["Wall S1"].variance, Some(5.0 * DAY));
        assert_eq!(late["Slab"].variance, Some(-2.0 * DAY));
    }

    #[test]
    fn schedule_refuses_a_date_that_is_not_finite() {
        let Some(scene) = scheduled() else { return };
        let err = scene.schedules()[0].at(f64::NAN, Dates::Scheduled).unwrap_err();
        assert_eq!(err.to_string(), "the date must be a finite number");
    }

    #[test]
    fn schedule_a_file_without_one_has_none() {
        let Some(scene) = two_cubes("schedule") else { return };
        assert!(scene.schedules().is_empty());
    }

    /// `Pose::raw_transform` against the real solved pose -- no geometry needed for this
    /// one, so `mechanism.stp` (kinematics only) is enough.
    #[test]
    fn a_pose_moves_the_arm_and_leaves_the_base_at_exactly_its_rest() {
        let Some(mechanism) = open_mechanism() else { return };
        let links = mechanism.links();
        let (base_node, arm_node) = (links[0].nodes()[0], links[1].nodes()[0]);
        let state = &mechanism.states()[0];
        let pose = mechanism.pose_state(state, None).unwrap();

        // The base is the pose's ground: bit-identical to its rest transform. The arm moved.
        assert_eq!(pose.raw_transform(base_node), base_node.raw_transform(), "the ground link stays exactly at rest");
        assert_ne!(pose.raw_transform(arm_node), arm_node.raw_transform(), "the arm should actually have moved");
    }

    #[test]
    fn a_pose_is_its_scene_by_handle_with_every_nodes_transform_set() {
        let Some(mechanism) = open_mechanism_solid() else { return };
        let pose = mechanism.pose_state(&mechanism.states()[0], None).unwrap();
        assert_eq!(pose.transforms.len(), mechanism.len(), "one transform per node, in index order");
        fake::take();
        mechanism.shown_with(fake::leaked(), Shown::Pose(&mechanism, &pose.transforms), &ViewOptions::default(), false).unwrap();
        let log = fake::take();
        assert_eq!(log[1], "show scene");
        assert_eq!(log[2], format!("node_transforms 21 {}", mechanism.len()), "set on the scene's item before drawing");
        assert_eq!(log.last().map(String::as_str), Some("destroy"));
    }

    /// The singular-rest refusal is the library's now (`cadaclysm-view`'s
    /// `set_node_transforms`, Ruling 18): the wrapper hands back its reason, naming the
    /// library, and still destroys the view.
    #[test]
    fn a_pose_the_library_refuses_is_its_error_and_the_view_is_destroyed() {
        let Some(mechanism) = open_mechanism_solid() else { return };
        let pose = mechanism.pose(&[], None).unwrap();
        fake::take();
        fake::failure(b"set_node_transforms: node 3 has a singular rest transform\0");
        fake::fail_at("node_transforms");
        let err = mechanism.shown_with(fake::leaked(), Shown::Pose(&mechanism, &pose.transforms), &ViewOptions::default(), false).unwrap_err();
        fake::fail_at("");
        fake::failure(b"fake failure\0");
        assert_eq!(err.message(), "fake 1.0: set_node_transforms: node 3 has a singular rest transform");
        assert_eq!(fake::take().last().map(String::as_str), Some("destroy"));
    }

    #[test]
    fn pose_view_returns_runs_camera_and_pick() {
        let Some(mechanism) = open_mechanism_solid() else { return };
        let pose = mechanism.pose(&[], None).unwrap();
        let camera = mechanism.shown_with(fake::leaked(), Shown::Pose(&mechanism, &pose.transforms), &ViewOptions::default(), true).unwrap().expect("a camera");
        assert_eq!(camera.pick, Some(crate::view::Pick { item: 3, node: 4, face: 5, clicks: 1, point: None }));
    }

    // ---- Node::silhouette_beziers --------------------------------------------------------
    // The fixtures are the repository's own. The box is our STEP writer's, not a Rhino export: Rhino
    // writes a planar face as a NURBS patch, so the exact-plane path would never be reached and an
    // empty answer would prove nothing. Each test skips quietly without the library or the fixture,
    // like this module's other library-needing tests.

    fn silhouette_fixture(name: &str) -> Option<Scene> {
        let path = format!("{}/../../../cadaclysm-acis/tests/fixtures/rhino/{name}", env!("CARGO_MANIFEST_DIR"));
        match open(&path) {
            Ok(scene) => Some(scene),
            Err(err) => {
                eprintln!("skipped: {err} (no library or no {name} to take a silhouette of)");
                None
            }
        }
    }

    /// The body node above the lump holds no shape of its own; the first node with extent is the part.
    fn silhouette_part(scene: &Scene) -> Node<'_> {
        scene.walk().find(|n| n.bounds64().size().iter().any(|s| *s > 0.0)).expect("the fixture has a part with extent")
    }

    #[test]
    fn a_spheres_control_points_stay_within_the_fit_budget_of_it_in_arrays_of_the_documented_lengths() {
        let Some(scene) = silhouette_fixture("sphere.sat") else { return };
        let node = silhouette_part(&scene);
        let iso = SvgOptions { view: SvgView::Iso, ..Default::default() };
        let rim = node.silhouette_beziers(&iso).unwrap();
        assert!(rim.count() > 0, "a sphere gave no rim");
        assert_eq!(rim.points.len(), rim.count() * 4);
        assert_eq!(rim.weights.len(), rim.count() * 4);
        assert!(rim.weights.iter().all(|w| w.is_finite() && *w > 0.0), "a weight is not finite and positive");
        // Every control point lies within the library's fit budget of the sphere, at the bounds
        // radius from the bounds centre. That is NOT because control points lie on the sphere: the
        // silhouette curve does, but a cubic's interior control points do not (here, on iso, they
        // stray up to 3.0e-3 where the end points stray under 1e-14). It holds because the arcs are
        // short (half a unit on a radius of 10), and the budget below is the tolerance the library
        // fits the CURVE to, not its control polygon. The margin is narrow: the curve itself uses
        // nearly the whole budget (3.42e-3 against 3.46e-3) since the lattice's spacing became a
        // length in space (44efabc88); before, a lattice ten times too fine left it at 1e-4. So this catches a displaced or scaled result and a mis-strided unpack.
        // It does NOT pin the eye or `up` (a silhouette point is a point of the surface, so it is
        // on the sphere from any view), the node choice (a wrong node fails earlier, as a refusal
        // or an empty answer), the weights (all 1.0 on this fixture), or the radius separately from
        // the centre (both come from the same bounds).
        // The bound is the library's own budget, `world_tolerance`: extent * (tolerance / width), read
        // off the options this call was given rather than copied from their defaults. The library's
        // extent is the box of the body's sampled feature edges, falling back to declared bounds only
        // when there are none; the node's bounds diagonal stands in for it, which can differ from
        // that box.
        // And it is blind to a one-CONTROL-POINT slip of the unpack. That is a shift of 3 doubles,
        // so every point is replaced by a DIFFERENT control point, which is within the budget just
        // the same: the worst deviation is the same before and after (3.0e-3 here on iso either
        // way, against a budget of about 3.5e-3). A one-DOUBLE slip is another matter: it mixes
        // coordinates across neighbouring points, leaves the sphere, and is caught (0.87 on iso,
        // 8.8 on front). The chaining assertion below is what catches the one-control-point slip.
        let b = node.bounds64();
        let (centre, size) = (b.centre(), b.size());
        let radius = size[0] / 2.0;
        let budget = (size[0] * size[0] + size[1] * size[1] + size[2] * size[2]).sqrt() * (iso.tolerance / iso.width);
        let worst = rim
            .points
            .iter()
            .map(|p| ((p[0] - centre[0]).powi(2) + (p[1] - centre[1]).powi(2) + (p[2] - centre[2]).powi(2)).sqrt() - radius)
            .fold(0.0f64, |worst, off| worst.max(off.abs()));
        assert!(radius > 0.0 && worst <= budget, "control points stray {worst} from the bounds centre's radius {radius}, past the budget {budget}");
        // Chaining: the last control point of arc c is the first of arc c + 1, to 1e-9 per coordinate
        // (each of x, y and z is tested, so a passing pair can be up to 1.73e-9 apart). The arcs come
        // back in RUNS, not as one ordered traversal, so this is a COUNT with a margin and not an
        // identity: on this iso answer 232 of the 235 consecutive pairs chain (98.7%, four runs). The
        // count drifts with how the sphere is tessellated; a lower bound of 80 is safe only because it
        // sits about three times below it. It has drifted once: the bound was 400 against 1206 of 1209
        // until the lattice's spacing became a length in space (44efabc88) and the same four runs came
        // back in arcs five times longer. (Front, which this test does not ask, chains much less: 96 of
        // 173 pairs, 55%, which is why a bound taken from the wrong view is either toothless or red.)
        // A slip of the unpack by one double or by one control point leaves none of them (0 of 235),
        // so the count falls from over two hundred to zero. Those figures are for wrap-around slips,
        // which keep the length and the count, so the denominator stays the unshifted pair count; a
        // truncating slip would drop it by one.
        // Its limit: a slip by a whole CURVE (12 doubles) PRESERVES the chaining (231 of 235 on iso,
        // 95 of 173 on front) and is NOT caught by this or by the radius check above.
        let chained = rim
            .points
            .chunks_exact(4)
            .zip(rim.points.chunks_exact(4).skip(1))
            .filter(|(curve, next)| (0..3).all(|axis| (curve[3][axis] - next[0][axis]).abs() <= 1e-9))
            .count();
        assert!(
            chained >= 80,
            "only {chained} of {} consecutive arcs chain (last control point = the next one's first), want at least 80",
            rim.count() - 1
        );
    }

    /// Asked larger first, so the second call refills the same slot in place (`refill` clears and
    /// extends the Vec: a larger second ask could grow and move the block, and a view would then read
    /// freed memory that merely still holds the old values). A view would show the second answer
    /// through the first, so the copy is the only thing this passes on. Here the answer is an owned
    /// `Vec`, which cannot be a view, so the assertions after the second call are STRUCTURAL: no
    /// mutation of this wrapper can fail them short of changing its return type. They are kept as the
    /// statement of the property, not as a witness of it; the Python and LuaJIT reader tests, whose
    /// answers can be views, are the witnessed ones.
    #[test]
    fn the_answer_is_the_callers_own_a_later_call_on_the_scene_leaves_it_alone() {
        let Some(scene) = silhouette_fixture("sphere.sat") else { return };
        let node = silhouette_part(&scene);
        let front = SvgOptions { view: SvgView::Front, ..Default::default() };
        let iso = SvgOptions { view: SvgView::Iso, ..Default::default() };
        // Iso is the larger (236 curves against front's 174); front was, 1248 against 1210, until the
        // lattice's spacing became a length in space (44efabc88).
        let first = node.silhouette_beziers(&iso).unwrap();
        let (kept_points, kept_weights) = (first.points[..].to_vec(), first.weights[..].to_vec());
        let second = node.silhouette_beziers(&front).unwrap();
        assert!(second.count() > 0, "the second view gave no rim");
        assert!(second.count() <= first.count(), "the larger answer must come first (iso {}, front {})", first.count(), second.count());
        assert_ne!(second.points[..], kept_points[..], "the two views gave the same silhouette, so this cannot tell a copy from a view");
        assert_eq!(first.points[..], kept_points[..], "the first answer's points changed under the second call");
        assert_eq!(first.weights[..], kept_weights[..], "the first answer's weights changed under the second call");
    }

    /// `Scene` is `Sync`, and the library documents that two threads calling this on one scene free
    /// each other's arrays, which is why `Node::silhouette_beziers` holds a lock. This checks that
    /// four threads asking alternately for two eyes each get the whole answer they asked for. It is
    /// a smoke test, not a proof of the lock: with the lock removed it still passed on this machine
    /// (three runs), so a race it would catch has not been shown.
    #[test]
    fn threads_asking_one_scene_each_get_their_own_answer() {
        let Some(scene) = silhouette_fixture("sphere.sat") else { return };
        let node = silhouette_part(&scene);
        let front = SvgOptions { view: SvgView::Front, ..Default::default() };
        let iso = SvgOptions { view: SvgView::Iso, ..Default::default() };
        let (want_front, want_iso) = (node.silhouette_beziers(&front).unwrap(), node.silhouette_beziers(&iso).unwrap());
        std::thread::scope(|scope| {
            for t in 0..4 {
                let (node, front, iso, want_front, want_iso) = (&node, &front, &iso, &want_front, &want_iso);
                scope.spawn(move || {
                    for i in 0..10 {
                        let (options, want) = if (t + i) % 2 == 0 { (front, want_front) } else { (iso, want_iso) };
                        let got = node.silhouette_beziers(options).unwrap();
                        assert_eq!(got.points[..], want.points[..], "thread {t}, ask {i}: points");
                        assert_eq!(got.weights[..], want.weights[..], "thread {t}, ask {i}: weights");
                    }
                });
            }
        });
    }

    /// `Node::silhouette_beziers` takes the scene's `silhouette` lock. With the test thread holding
    /// it, a call on another thread must not complete; once it is released, the call completes. Only
    /// the first half is timing-based, and the timeout is a floor rather than a margin: it has to be
    /// long enough that the spawned thread has certainly reached the call and blocked, so that a
    /// pass means it waited there rather than that it had not started yet. 2 s is far longer than a
    /// thread needs to get there, and a call that ignored the lock returns in well under a second
    /// here, so the only cost of the margin is 2 s on a green run. This proves the call waits for
    /// the lock. It does NOT prove the lock is held across the copy out of the library's slot: that
    /// would need a hook between the C call and the copy, which the C ABI does not offer.
    #[test]
    fn the_silhouette_call_waits_for_the_scenes_lock() {
        let Some(scene) = silhouette_fixture("sphere.sat") else { return };
        let node = silhouette_part(&scene);
        let (done, completed) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            // Taken inside the scope's closure so that a failed assertion drops it while unwinding,
            // before the scope joins the spawned thread, which would otherwise wait on it for ever.
            let held = scene.silhouette.lock().unwrap();
            scope.spawn(move || done.send(node.silhouette_beziers(None).map(|beziers| beziers.count())).unwrap());
            assert!(
                completed.recv_timeout(std::time::Duration::from_millis(2000)).is_err(),
                "the silhouette call completed while the scene's lock was held, so it does not take it"
            );
            drop(held);
            let count = completed.recv().expect("the call never completed after the lock was released").unwrap();
            assert!(count > 0, "a sphere gave no rim");
        });
    }

    /// The twin of the test above, for the `svg_text` slot: `Scene::svg_text` and `Node::svg_text` both
    /// take the scene's `svg_text` lock (a different mutex from the silhouette one, so the test above
    /// cannot witness it). With the test thread holding it, a call to each on its own thread must not
    /// complete; once it is released, both do. Same shape and same cost as the silhouette twin: only
    /// the first half is timing-based, and 2 s is a floor, not a margin, long enough that the spawned
    /// threads have certainly reached their calls and blocked. Like that test, it proves the calls wait
    /// for the lock, not that the lock is held across the copy out of the library's slot.
    #[test]
    fn the_svg_text_calls_wait_for_the_scenes_lock() {
        let Some(scene) = silhouette_fixture("sphere.sat") else { return };
        let node = silhouette_part(&scene);
        let (done, completed) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            // Taken inside the scope's closure so that a failed assertion drops it while unwinding,
            // before the scope joins the spawned threads, which would otherwise wait on it for ever.
            let held = scene.svg_text.lock().unwrap();
            let (scene, node) = (&scene, &node);
            let from_scene = done.clone();
            scope.spawn(move || from_scene.send(("Scene::svg_text", scene.svg_text(None).map(|text| text.len()))).unwrap());
            scope.spawn(move || done.send(("Node::svg_text", node.svg_text(None).map(|text| text.len()))).unwrap());
            assert!(
                completed.recv_timeout(std::time::Duration::from_millis(2000)).is_err(),
                "an svg_text call completed while the scene's svg_text lock was held, so it does not take it"
            );
            drop(held);
            for _ in 0..2 {
                let (which, length) = completed.recv().expect("an svg_text call never completed after the lock was released");
                assert!(length.unwrap() > 0, "{which} gave no text");
            }
        });
    }

    #[test]
    fn an_infinite_tolerance_is_refused_and_an_all_planar_body_is_the_empty_answer_after_it() {
        let Some(scene) = silhouette_fixture("box-chamfer-all.blacksmith.stp") else { return };
        let node = silhouette_part(&scene);
        let infinite = SvgOptions { tolerance: f64::INFINITY, ..Default::default() };
        let err = node.silhouette_beziers(&infinite).unwrap_err();
        assert!(err.message().contains("silhouette: "), "{err}");
        // The refusal above left its reason in the thread's error slot; the empty answer must not
        // read it as its own.
        let none = node.silhouette_beziers(None).expect("an empty silhouette is an answer");
        assert_eq!(none.count(), 0);
        assert!(none.points.is_empty() && none.weights.is_empty());
    }

    // ---- the health report and healing (healing in the other wrappers, 2026-10-29) ------

    fn rel(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol * b.abs().max(f64::MIN_POSITIVE)
    }

    /// `st203-bapl.stp` at the repository root (or `SAMPLE_DIR`), as Python's tests find it,
    /// and its breps in node order. Skips quietly without the sample or the library.
    fn st203() -> Option<(Scene, Vec<Brep>)> {
        let dir = std::env::var("SAMPLE_DIR")
            .unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/../../../..").to_string());
        let path = Path::new(&dir).join("st203-bapl.stp");
        if !path.exists() {
            eprintln!("skipped: {} not to hand", path.display());
            return None;
        }
        match open(&path) {
            Ok(scene) => {
                let breps = scene.nodes().iter().filter_map(|n| n.brep()).collect();
                Some((scene, breps))
            }
            Err(err) => {
                eprintln!("skipped: {err} (no library to open st203-bapl.stp with)");
                None
            }
        }
    }

    #[test]
    fn brep_health_reports_the_free_edges_of_st203_bapl() {
        let Some((_scene, breps)) = st203() else { return };
        let body = &breps[1]; // the 188-free-edge body; body 0 takes minutes to diagnose
        assert_eq!(body.manifold().unwrap().boundary_edges, 188);
        let report = body.health(None, false).unwrap();
        assert_eq!((report.free_edges.len(), report.wires.len()), (188, 45));
        assert_eq!(report.wires.iter().map(|w| w.count).sum::<u32>(), 188);
        assert_eq!(report.wire_edges(0), &report.free_edges[..report.wires[0].count as usize]);
        assert!(report.wire_edges(0).iter().all(|e| e.wire == 0));
        assert!(report.wire_edges(45).is_empty());
        let (_sewn, sew) = body.sewed(None, None).unwrap();
        assert_eq!(report.sew_pairs, sew.pairs);
        assert!(report.tolerance > 0.0 && report.cracks.is_none());
        assert_eq!(body.health(Some(f64::NAN), false).unwrap().tolerance, report.tolerance);
        let first = &report.free_edges[0];
        assert_eq!(
            (first.trim, first.edge, first.face, first.wire, first.partner, first.shared_ends),
            (0, Some(41363), 0, 0, Some(67), 0)
        );
        assert!(rel(first.gap, 95.01496054, 1e-6), "{}", first.gap);
        assert!(report.free_edges.iter().all(|e| e.partner.is_some() || e.gap == f64::INFINITY));
        assert!(rel(report.extent, 253.66439715552204, 1e-12), "{}", report.extent);
        assert!(rel(report.rounding, 1e-7 * report.extent, 1e-12));
        assert!(rel(report.tolerance, 1e-4 * report.extent, 1e-12));
        assert_eq!((report.loose_edges, report.worst_loose), (0, 0.0));
        assert_eq!((report.sew_refused, sew.refused), (4, 4));
        assert!(rel(report.sew_worst_gap, sew.worst_gap, 1e-12) && report.sew_worst_gap > 0.0);
        let cracks = body.health(None, true).unwrap().cracks.expect("cracks were asked for");
        assert_eq!(cracks, Cracks { watertight: false, open: 0, folded: 0, crossings: 166, edges: vec![] });
        let wide = body.health(Some(5.0), false).unwrap();
        assert_eq!(wide.small.len(), 96);
        let kinds: std::collections::BTreeSet<&str> = wide.small.iter().map(|s| s.kind.as_str()).collect();
        assert_eq!(kinds, ["short_edge", "sliver_face", "tiny_face"].into_iter().collect());
        let edge = wide.small.iter().find(|s| s.kind == "short_edge").unwrap();
        assert_eq!(edge.index, 41550);
        assert!(rel(edge.size, 3.1622776616321775, 1e-9), "{}", edge.size);
    }

    #[test]
    fn brep_healed_heals_st203_bapl_and_leaves_the_original() {
        let Some((_scene, breps)) = st203() else { return };
        let body = &breps[1];
        let (same, report) = body.healed(None, HealKinds::default()).unwrap();
        assert_ne!(same.pointer(), body.pointer());
        assert_eq!((report.small_before, report.free_before), (0, 188));
        assert!(rel(report.tolerance, 1e-4 * body.health(None, false).unwrap().extent, 1e-12));
        let (healed, report) = body.healed(Some(5.0), HealKinds::default()).unwrap();
        assert_eq!(report.tolerance, 5.0);
        assert_eq!((report.small_before, report.fixes.len(), report.small_after), (96, 28, 8));
        assert_eq!((report.free_before, report.free_after), (188, 88));
        assert!(!report.guarded || report.refused.iter().all(|r| r.why == "body_guard"));
        let refused: Vec<_> = report.refused.iter().map(|r| (r.kind.as_str(), r.why.as_str())).collect();
        assert_eq!(refused, vec![("sliver_face", "uneven"); 8]);
        assert_eq!(
            (report.closed_before, report.closed_after, report.nonmanifold_before, report.nonmanifold_after),
            (false, false, 0, 0)
        );
        assert_eq!(report.small_after as usize, healed.health(Some(5.0), false).unwrap().small.len());
        assert_eq!(body.health(Some(5.0), false).unwrap().small.len(), 96, "the input is left as it was");
        assert!(report.fixes.iter().all(|f| f.size >= 0.0 && f.moved >= 0.0));
        let furthest = report.fixes.iter().map(|f| f.moved).fold(0.0, f64::max);
        assert!(rel(furthest, 1.8248105306211464, 1e-9), "{furthest}");
        assert!(rel(report.moved, 1.581138831332503, 1e-9), "{}", report.moved);
        let edge = report.fixes.iter().find(|f| f.kind == "short_edge").unwrap();
        assert_eq!(edge.index, 41550);
        assert!(rel(edge.size, 3.1622776616321775, 1e-9));
        assert_eq!(body.edge_tolerance(41550), Some(0.0));
        assert_eq!(healed.edge_tolerance(41550), None);
        assert_eq!(healed.edge_tolerance(41363), Some(0.0));
        assert_eq!(healed.edge_tolerance(0xFFFF_FFF0), None);
        let off = HealKinds { edges: false, faces: false, holes: false };
        let (_, off) = body.healed(Some(5.0), off).unwrap();
        assert!(off.fixes.is_empty() && off.refused.len() == 96 && off.free_after == off.free_before);
        assert!(off.refused.iter().all(|r| r.why == "toggled" && r.figure == 0.0));
        let per_kind: Vec<usize> = ["short_edge", "sliver_face", "tiny_face"]
            .iter()
            .map(|k| off.refused.iter().filter(|r| r.kind == *k).count())
            .collect();
        assert_eq!(per_kind, [64, 26, 6]);
        // edges alone: only edge fixes, every other kind refused as toggled
        let (_, edges_only) = body.healed(Some(5.0), HealKinds { edges: true, faces: false, holes: false }).unwrap();
        assert!(edges_only.refused.iter().filter(|r| r.kind != "short_edge").all(|r| r.why == "toggled"));
        assert!(edges_only.fixes.iter().all(|f| f.kind == "short_edge" || f.kind == "collapsed_edge"));
        assert!(!edges_only.fixes.is_empty());
    }

    #[test]
    fn the_health_decoder_reads_every_column_of_distinct_rows() {
        let none = 0xFFFF_FFFF;
        let counts = [2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2];
        let sizes = [0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5];
        let free_ids = [10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0];
        let free_sizes = [1.5, 2.5, 3.5, f64::INFINITY];
        let r = health_report(&counts, &sizes, &free_ids, &free_sizes, &[0, 2, 1], &[8.5, 2.5], &[1, 77, 4, 99], &[0.125, 0.0625], &[5, 6])
            .unwrap();
        assert_eq!((r.tolerance, r.rounding, r.extent, r.worst_gap), (0.5, 0.25, 9.0, 7.5));
        assert_eq!((r.loose_edges, r.worst_loose, r.sew_pairs, r.sew_refused, r.sew_worst_gap), (3, 6.5, 4, 5, 5.5));
        assert_eq!(
            r.free_edges,
            vec![
                FreeEdge { trim: 10, edge: Some(20), face: 30, wire: 40, partner: Some(1), shared_ends: 2, length: 1.5, gap: 2.5 },
                FreeEdge { trim: 11, edge: None, face: 31, wire: 41, partner: None, shared_ends: 0, length: 3.5, gap: f64::INFINITY },
            ]
        );
        assert_eq!(r.wires, vec![FreeWire { first: 0, count: 2, closed: true, length: 8.5, widest_gap: 2.5 }]);
        assert_eq!(
            r.small,
            vec![
                SmallFeature { kind: "collapsed_edge".into(), index: 77, size: 0.125 },
                SmallFeature { kind: "tiny_body".into(), index: 99, size: 0.0625 },
            ]
        );
        assert_eq!(r.cracks, Some(Cracks { watertight: false, open: 11, folded: 12, crossings: 13, edges: vec![5, 6] }));
        // not meshed: no cracks, whatever the other five counts hold
        let mut unmeshed = counts;
        unmeshed[12] = 0;
        let r = health_report(&unmeshed, &sizes, &[], &[], &[], &[], &[], &[], &[5, 6]).unwrap();
        assert_eq!(r.cracks, None);
        assert!(health_report(&counts, &sizes, &[], &[], &[], &[], &[6, 0], &[0.0], &[]).is_err(), "kind 6 is no kind");
    }

    #[test]
    fn the_heal_decoder_reads_every_column_of_distinct_rows() {
        let counts = [2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4];
        let sizes = [0.5, 0.25];
        let r = heal_report(&counts, &sizes, &[5, 11, 0, 12], &[1.5, 0.125, 2.5, 0.0625], &[3, 21, 9, 4, 22, 3, 2, 23, 10], &[0.0, 7.5, 0.0])
            .unwrap();
        assert_eq!((r.tolerance, r.moved, r.guarded), (0.5, 0.25, true));
        assert_eq!((r.small_before, r.small_after, r.free_before, r.free_after), (9, 8, 7, 6));
        assert_eq!((r.closed_before, r.closed_after, r.nonmanifold_before, r.nonmanifold_after), (true, false, 5, 4));
        assert_eq!(
            r.fixes,
            vec![
                HealFix { kind: "small_hole".into(), index: 11, size: 1.5, moved: 0.125 },
                HealFix { kind: "short_edge".into(), index: 12, size: 2.5, moved: 0.0625 },
            ]
        );
        assert_eq!(
            r.refused,
            vec![
                HealRefusal { kind: "tiny_face".into(), index: 21, why: "toggled".into(), figure: 0.0 },
                HealRefusal { kind: "tiny_body".into(), index: 22, why: "chain".into(), figure: 7.5 },
                HealRefusal { kind: "sliver_face".into(), index: 23, why: "unsupported".into(), figure: 0.0 },
            ]
        );
        assert!(heal_report(&counts, &sizes, &[], &[], &[0, 1, 11], &[0.0]).is_err(), "why 11 is no why");
    }

    #[test]
    fn heal_kinds_are_the_c_flag_bits() {
        assert_eq!(HealKinds::default().flags(), 7);
        assert_eq!(HealKinds { edges: true, faces: false, holes: false }.flags(), 1);
        assert_eq!(HealKinds { edges: false, faces: true, holes: false }.flags(), 2);
        assert_eq!(HealKinds { edges: false, faces: false, holes: true }.flags(), 4);
        assert_eq!(HealKinds { edges: false, faces: false, holes: false }.flags(), 0);
    }
}
