//! Drawing through a view library: [`View`], and `solid.show(..)`, `scene.view(..)`.
//!
//! A view library implements `cadaclysm_view.h`. The SDK bundles two: `cadaclysm_terminal`,
//! the default, which draws with sixel, the kitty graphics protocol or coloured half
//! blocks; and `cadaclysm_view` (wgpu, after [`use_wgpu`]), windows of its own, a host's
//! window, offscreen views. The same calls draw through either.

pub mod sys;

mod options;

mod items;

mod machining;

mod target;

pub(crate) mod objects;

#[cfg(target_arch = "wasm32")]
pub(crate) mod web_lib;

mod control;

mod png;

mod colour;

mod text;

mod overlay;

pub use colour::{Colour, Rgb, Rgba};
pub use options::{Camera, Lighting, Navigation, Pick, SurfaceMode, ViewOptions};
pub use items::{Finish, Item, Material, Occluded, SolidOptions, View};
pub use machining::{ColourBy, Machining, MachiningInfo, MachiningOptions, MachiningPart, MachiningProgram, MachiningTool, ToolShape};
pub use text::{Align, Text, TextMode};
pub use overlay::{Anchor, Overlay, OverlayStyle};
pub use target::{RawWindow, WindowKind};
pub use control::{Button, Event, Grid, Image, Input, Layer, LineColour, Lod, LodMotion, OccludedStyle, Pointer, Snap, SnapKind, Standard, Stats, Viewport, WorkPlane};

#[cfg(not(target_arch = "wasm32"))]
use std::ffi::OsString;
use std::path::{Path, PathBuf};
#[cfg(not(target_arch = "wasm32"))]
use std::sync::{Mutex, MutexGuard};

use crate::loader::Library as Dylib;

use crate::{loader, text, Error, Result};

/// The variable naming the bundled terminal library (the library, or its directory).
const TERMINAL_VARIABLE: &str = "CADACLYSM_TERMINAL_LIBRARY";

/// The variable naming the wgpu view library, `cadaclysm_view` (the library, or its directory).
const WGPU_VARIABLE: &str = "CADACLYSM_VIEW_LIBRARY";

/// A loaded viewer library. Loaded once per path per process and never unloaded, so the
/// `&'static Library` that [`use_library`] and [`current`] hand out stays valid.
pub struct Library {
    api: sys::Api,
    name: String,
    path: PathBuf,
    version: u32,
    // Never dropped: every pointer in `api` points into it.
    _library: Option<Dylib>,
}

impl std::fmt::Debug for Library {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Library")
            .field("name", &self.name)
            .field("path", &self.path)
            .field("abi_version", &self.abi_version())
            .finish()
    }
}

impl Library {
    /// What the library calls itself -- `cadaclysm_view_name()`, e.g.
    /// `"cadaclysm-terminal 0.8.0"`.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The file it was loaded from, canonical (absolute, links resolved) when it could
    /// be made so.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `(major, minor)` of the contract the library implements.
    pub fn abi_version(&self) -> (u16, u16) {
        ((self.version >> 16) as u16, (self.version & 0xFFFF) as u16)
    }

    /// Whether this is the terminal library (`cadaclysm_view_name()` starting
    /// `cadaclysm-terminal`): `show` prints a still there and blocks in a window elsewhere.
    pub fn is_terminal(&self) -> bool {
        self.name.starts_with("cadaclysm-terminal")
    }

    pub(crate) fn api(&self) -> &sys::Api {
        &self.api
    }

    /// The library's reason for this thread's last failure, as it gave it.
    pub(crate) fn last_error(&self) -> String {
        unsafe { text((self.api.cadaclysm_view_last_error)()) }
    }

    /// `"{name}: {last_error}"` -- the library's reason for this thread's last failure.
    pub(crate) fn error(&self) -> Error {
        Error::new(format!("{}: {}", self.name, self.last_error()))
    }

    /// `ok` from a call's own return -- `true` to `Ok(())`, `false` to [`Library::error`].
    /// Shared by [`View::check`](super::View) and [`Item::check`](super::Item): every raw
    /// call that reports success as a `bool` reads its failure the same way.
    pub(super) fn check(&self, ok: bool) -> Result<()> {
        if ok {
            Ok(())
        } else {
            Err(self.error())
        }
    }

    fn from_api(api: sys::Api, path: PathBuf, library: Option<Dylib>) -> Result<Library> {
        let version = unsafe { (api.cadaclysm_view_abi_version)() };
        check_abi_version(version, &path)?;
        let name = unsafe { text((api.cadaclysm_view_name)()) };
        Ok(Library { api, name, path, version, _library: library })
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn open(path: &Path) -> Result<Library> {
        // SAFETY: loading runs the library's initialisers and every symbol is then read as
        // the header declares it -- the contract of loading a view library at all.
        let library = unsafe { Dylib::new(path) }
            .map_err(|e| Error::new(format!("{}: could not load the view library: {e}", path.display())))?;
        // The ABI version first: a real 1.2 library has every symbol here except
        // `cadaclysm_view_name` (added in 1.3), so binding the whole table in declaration
        // order would raise "not a view library" for it instead of the ABI message.
        // Checking the version before binding the rest reports the true reason -- Python's
        // `_load` does the same.
        let abi_version = unsafe { library.get::<unsafe extern "C" fn() -> u32>(b"cadaclysm_view_abi_version\0") }
            .map_err(|_| Error::new(format!("{}: not a view library (no cadaclysm_view_abi_version)", path.display())))?;
        let version = unsafe { abi_version() };
        check_abi_version(version, path)?;
        drop(abi_version);
        let api = unsafe { sys::Api::bind(&library, path, None) }.map_err(|_| {
            let missing = sys::ENTRY_POINTS
                .iter()
                .find(|name| unsafe { library.get::<*const ()>(format!("{name}\0").as_bytes()) }.is_err())
                .copied()
                .unwrap_or("an entry point");
            Error::new(format!("{}: not a view library (no {missing})", path.display()))
        })?;
        Library::from_api(api, canonical(path), Some(library))
    }
}

/// `version` (`cadaclysm_view_abi_version`'s packed `major << 16 | minor`) against what this
/// SDK needs, shared by [`Library::open`] (checked before binding the rest of the table, so a
/// too-old library gets this message rather than "not a view library") and
/// [`Library::from_api`] (the in-process fake used by tests, which skips `open`'s loading).
fn check_abi_version(version: u32, path: &Path) -> Result<()> {
    let (major, minor) = (version >> 16, version & 0xFFFF);
    if major != sys::CADACLYSM_VIEW_ABI_MAJOR || minor < sys::CADACLYSM_VIEW_ABI_MINOR {
        return Err(Error::new(abi_mismatch(major, minor, path, loader::BUILD_ERROR)));
    }
    Ok(())
}

/// The message for a view library of ABI `major.minor`, with why the build gave no
/// libraries of its own (`build_error`) when it gave none: the too-old library is then
/// usually one an earlier build left beside the binaries.
fn abi_mismatch(major: u32, minor: u32, path: &Path, build_error: Option<&str>) -> String {
    loader::with_build_note(
        format!(
            "{}: view ABI {major}.{minor}, this SDK needs {}.{} or a later {}.x",
            path.display(),
            sys::CADACLYSM_VIEW_ABI_MAJOR,
            sys::CADACLYSM_VIEW_ABI_MINOR,
            sys::CADACLYSM_VIEW_ABI_MAJOR
        ),
        build_error,
    )
}

#[cfg(not(target_arch = "wasm32"))]
static LOADED: Mutex<Vec<&'static Library>> = Mutex::new(Vec::new());
#[cfg(not(target_arch = "wasm32"))]
static CURRENT: Mutex<Option<&'static Library>> = Mutex::new(None);

/// A poisoned lock still holds a consistent list: nothing panics while holding one.
#[cfg(not(target_arch = "wasm32"))]
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `path` absolute with its links resolved, so one file named two ways (or a relative
/// path named again after the working directory moved) is one key; as given when it
/// cannot be resolved.
#[cfg(not(target_arch = "wasm32"))]
fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// The viewer at `path`, loading it the first time it is named.
#[cfg(not(target_arch = "wasm32"))]
fn loaded(path: &Path) -> Result<&'static Library> {
    let wanted = canonical(path);
    let mut all = lock(&LOADED);
    if let Some(viewer) = all.iter().find(|v| v.path == wanted) {
        return Ok(viewer);
    }
    let viewer: &'static Library = Box::leak(Box::new(Library::open(path)?));
    all.push(viewer);
    Ok(viewer)
}

#[cfg(not(target_arch = "wasm32"))]
fn make_current(viewer: &'static Library) -> &'static Library {
    *lock(&CURRENT) = Some(viewer);
    viewer
}

/// Draw with the viewer library at `path` from now on. A library already loaded is
/// reused, not opened again. Returns it.
pub fn use_library(path: impl AsRef<Path>) -> Result<&'static Library> {
    #[cfg(target_arch = "wasm32")]
    return Err(Error::new(format!(
        "view::use_library: a view library file ({}) isn't available in the browser; the web package's View draws there",
        path.as_ref().display()
    )));
    #[cfg(not(target_arch = "wasm32"))]
    Ok(make_current(loaded(path.as_ref())?))
}

/// Draw with the terminal library bundled with the SDK from now on, whatever was in use.
pub fn use_terminal() -> Result<&'static Library> {
    #[cfg(target_arch = "wasm32")]
    return Ok(web_lib::library());
    #[cfg(not(target_arch = "wasm32"))]
    use_library(terminal_library()?)
}

/// Draw with the wgpu library, `cadaclysm_view`, from now on: windows of its own, a host's
/// window, offscreen views. Where it is not found, the error names the places searched.
pub fn use_wgpu() -> Result<&'static Library> {
    #[cfg(target_arch = "wasm32")]
    return Ok(web_lib::library());
    #[cfg(not(target_arch = "wasm32"))]
    use_library(wgpu_library()?)
}

/// Loads a TrueType or OpenType font (the bytes of a `.ttf`/`.otf`, copied) into the
/// library in use and returns its id, for [`Text::font`] (0 is the built-in face). The
/// error carries the library's reason when the bytes are not a font.
pub fn load_font(bytes: &[u8]) -> Result<u32> {
    load_font_with(current()?, bytes)
}

pub(crate) fn load_font_with(library: &Library, bytes: &[u8]) -> Result<u32> {
    let id = unsafe { (library.api().cadaclysm_view_load_font)(bytes.as_ptr(), bytes.len()) };
    if id == 0 {
        return Err(library.error());
    }
    Ok(id)
}

/// The library `show`, `view` and [`View`] draw with: the last [`use_library`],
/// [`use_terminal`] or [`use_wgpu`]; else what `CADACLYSM_VIEW` names (`terminal`, `wgpu`
/// or a path); else the bundled terminal library. A failure is not remembered -- the next
/// call looks again.
pub fn current() -> Result<&'static Library> {
    #[cfg(target_arch = "wasm32")]
    return Ok(web_lib::library());
    #[cfg(not(target_arch = "wasm32"))]
    {
        if let Some(library) = *lock(&CURRENT) {
            return Ok(library);
        }
        let path = match choose(std::env::var_os("CADACLYSM_VIEW"))? {
            Choice::Terminal => terminal_library()?,
            Choice::Wgpu => wgpu_library()?,
            Choice::Path(path) => path,
        };
        let library = loaded(&path)?;
        // A `use_library` on another thread since the check above wins: the default only
        // fills an empty slot.
        Ok(*lock(&CURRENT).get_or_insert(library))
    }
}

/// What `CADACLYSM_VIEW` asks for.
#[cfg(not(target_arch = "wasm32"))]
#[derive(Debug, PartialEq, Eq)]
enum Choice {
    Terminal,
    Wgpu,
    Path(PathBuf),
}

/// `CADACLYSM_VIEW`: unset or empty is the terminal; `terminal` and `wgpu` name the two
/// libraries; anything else is a file that must exist.
#[cfg(not(target_arch = "wasm32"))]
fn choose(named: Option<OsString>) -> Result<Choice> {
    let Some(value) = named.filter(|value| !value.is_empty()) else { return Ok(Choice::Terminal) };
    match value.to_str() {
        Some("terminal") => return Ok(Choice::Terminal),
        Some("wgpu") => return Ok(Choice::Wgpu),
        _ => {}
    }
    let path = PathBuf::from(value);
    if path.is_file() {
        Ok(Choice::Path(path))
    } else if path.is_dir() {
        Err(Error::new(format!("CADACLYSM_VIEW={} is a directory, not a view library", path.display())))
    } else {
        Err(Error::new(format!("CADACLYSM_VIEW={} names nothing that exists", path.display())))
    }
}

/// Where the bundled terminal library is, without loading it: `CADACLYSM_TERMINAL_LIBRARY`
/// (the library or its directory) when set; else the search the reader and kernel
/// libraries get -- beside the executable, where the build downloaded, a `lib/` or a
/// `target/release`/`target/debug` above the executable or the working directory.
pub fn terminal_library() -> Result<PathBuf> {
    loader::find(&[loader::file_name("cadaclysm_terminal")], &[TERMINAL_VARIABLE])
        .map_err(|message| no_library(message, "terminal", TERMINAL_VARIABLE))
}

/// Where the wgpu library, `cadaclysm_view`, is, without loading it: `CADACLYSM_VIEW_LIBRARY`
/// (the library or its directory) when set; else the same search as [`terminal_library`].
pub fn wgpu_library() -> Result<PathBuf> {
    loader::find(&[loader::file_name("cadaclysm_view")], &[WGPU_VARIABLE])
        .map_err(|message| no_library(message, "wgpu", WGPU_VARIABLE))
}

/// The error for `loader::find`'s `message` about the `what` library: the places it
/// searched (its indented lines) and any download error, in the view's words -- not the
/// loader's closing advice. A `variable` set and wrong is reported as the loader said it.
fn no_library(message: String, what: &str, variable: &str) -> Error {
    if message.starts_with(variable) {
        return Error::new(message);
    }
    let searched: Vec<&str> = message.lines().filter_map(|line| line.strip_prefix("    ")).collect();
    let mut text = format!(
        "no view library: the {what} library was not found (searched: {}) -- set {variable} \
         to it, or CADACLYSM_VIEW to another view library",
        searched.join(", ")
    );
    if let Some(download) = message.lines().find(|line| line.starts_with(loader::BUILD_NOTE)) {
        text.push('\n');
        text.push_str(download);
    }
    Error::new(text)
}

#[cfg(test)]
pub(crate) mod fake;

#[cfg(test)]
pub(crate) fn target_own() -> target::Target {
    target::Target::Own
}

// The library choice and loading are native; on wasm32 the web table is the library.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use std::ffi::OsString;

    /// Serialises the tests that set the process-wide current viewer.
    static CURRENT_LOCK: Mutex<()> = Mutex::new(());

    /// A test that cannot run without a real library skips -- unless
    /// `CADACLYSM_REQUIRE_TERMINAL=1`, as CI, the Linux box and the Windows gate set it.
    fn skip(why: impl std::fmt::Display) {
        if std::env::var("CADACLYSM_REQUIRE_TERMINAL").as_deref() == Ok("1") {
            panic!("CADACLYSM_REQUIRE_TERMINAL=1, but: {why}");
        }
        eprintln!("skipped: {why}");
    }

    /// A test that needs the wgpu library or a GPU adapter skips -- unless
    /// `CADACLYSM_REQUIRE_WGPU` is set, as the Linux box and the Windows gate set it.
    fn skip_wgpu(why: impl std::fmt::Display) {
        if std::env::var("CADACLYSM_REQUIRE_WGPU").as_deref() == Ok("1") {
            panic!("CADACLYSM_REQUIRE_WGPU=1, but: {why}");
        }
        eprintln!("skipped: {why}");
    }

    #[test]
    fn a_viewer_reports_its_name_and_version() {
        let v = fake::library();
        assert_eq!(v.name(), "fake 1.0");
        assert_eq!(v.abi_version(), (1, 25));
        assert_eq!(v.path(), Path::new("fake"));
    }

    /// The eleven calls with no return value to report failure on (orbit, pan, look, zoom,
    /// dolly, set_orthographic, set_background, request_pick, request_pick_in, request_snap_in,
    /// clear_snap) must still
    /// clear a stale `last_error`, as every other successful call does (ruling F16) -- a
    /// host that checks `last_error` after one of them must not see an earlier failure's
    /// reason. `frame` leaves the stale error each time; it is not one of the eleven.
    #[test]
    fn every_void_call_clears_a_stale_last_error() {
        let api = fake::api();
        let opts = sys::CadaclysmViewOptions {
            size: std::mem::size_of::<sys::CadaclysmViewOptions>() as u32,
            surfaces: 0,
            backend: 0,
            y_up: 0,
            title: std::ptr::null(),
            width: 0,
            height: 0,
            offscreen: 0,
        };
        let view = unsafe { (api.cadaclysm_view_create)(std::ptr::null(), &opts) };
        let last_error = || unsafe { crate::text((api.cadaclysm_view_last_error)()) };
        let leave_a_stale_error = || {
            fake::fail_at("frame");
            unsafe { (api.cadaclysm_view_frame)(view, 0) };
            fake::fail_at("");
            assert_ne!(last_error(), "", "frame should have left a stale error");
        };
        let background = [0.1f32, 0.2, 0.3];

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_orbit)(view, 1.0, 2.0) };
        assert_eq!(last_error(), "", "orbit");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_pan)(view, 1.0, 2.0) };
        assert_eq!(last_error(), "", "pan");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_look)(view, 1.0, 2.0) };
        assert_eq!(last_error(), "", "look");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_zoom)(view, 1.0) };
        assert_eq!(last_error(), "", "zoom");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_dolly)(view, 1.0) };
        assert_eq!(last_error(), "", "dolly");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_set_orthographic)(view, true) };
        assert_eq!(last_error(), "", "set_orthographic");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_set_background)(view, background.as_ptr()) };
        assert_eq!(last_error(), "", "set_background");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_request_pick)(view, 1, 2) };
        assert_eq!(last_error(), "", "request_pick");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_request_pick_in)(view, 0, 1, 2) };
        assert_eq!(last_error(), "", "request_pick_in");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_request_snap_in)(view, 0, 1, 2) };
        assert_eq!(last_error(), "", "request_snap_in");

        leave_a_stale_error();
        unsafe { (api.cadaclysm_view_clear_snap)(view) };
        assert_eq!(last_error(), "", "clear_snap");

        unsafe { (api.cadaclysm_view_destroy)(view) };
    }

    #[test]
    fn another_abi_major_is_refused_with_both_versions() {
        fake::abi((2 << 16) | 5);
        let err = Library::from_api(fake::api(), PathBuf::from("v2.dll"), None).expect_err("ABI 2 refused");
        fake::abi((1 << 16) | 25);
        assert_eq!(err.message(), "v2.dll: view ABI 2.5, this SDK needs 1.25 or a later 1.x");
    }

    #[test]
    fn an_abi_mismatch_says_why_the_build_gave_no_libraries() {
        let reason = "they were not built from R:\\src: cargo build failed";
        let m = abi_mismatch(1, 5, Path::new("old.dll"), Some(reason));
        assert_eq!(
            m,
            "old.dll: view ABI 1.5, this SDK needs 1.25 or a later 1.x\n\
             The build gave no libraries of its own: they were not built from R:\\src: cargo build failed"
        );
        assert_eq!(abi_mismatch(1, 5, Path::new("old.dll"), None), "old.dll: view ABI 1.5, this SDK needs 1.25 or a later 1.x");
    }

    #[test]
    fn a_minor_version_below_25_is_refused_with_the_abi_message() {
        fake::abi((1 << 16) | 4);
        let err = Library::from_api(fake::api(), PathBuf::from("v1.4.dll"), None).expect_err("1.4 is too old");
        fake::abi((1 << 16) | 25);
        assert_eq!(err.message(), "v1.4.dll: view ABI 1.4, this SDK needs 1.25 or a later 1.x");
        fake::abi((1 << 16) | 24);
        let err = Library::from_api(fake::api(), PathBuf::from("v1.24.dll"), None).expect_err("1.24 is too old");
        fake::abi((1 << 16) | 25);
        assert_eq!(err.message(), "v1.24.dll: view ABI 1.24, this SDK needs 1.25 or a later 1.x");
    }

    #[test]
    fn a_later_minor_version_is_accepted() {
        fake::abi((1 << 16) | 26);
        let v = Library::from_api(fake::api(), PathBuf::from("v1.26"), None);
        fake::abi((1 << 16) | 25);
        assert_eq!(v.expect("1.26 is 1.25 or later").abi_version(), (1, 26));
    }

    #[test]
    fn cadaclysm_view_names_a_library_by_name_or_by_path() {
        let exe = std::env::current_exe().unwrap();
        assert_eq!(choose(Some(OsString::from(&exe))).unwrap(), Choice::Path(exe));
        assert_eq!(choose(Some(OsString::from("wgpu"))).unwrap(), Choice::Wgpu);
        assert_eq!(choose(Some(OsString::from("terminal"))).unwrap(), Choice::Terminal);
    }

    #[test]
    fn no_or_an_empty_cadaclysm_view_is_the_terminal() {
        assert_eq!(choose(None).unwrap(), Choice::Terminal);
        assert_eq!(choose(Some(OsString::new())).unwrap(), Choice::Terminal);
    }

    #[test]
    fn a_cadaclysm_view_naming_nothing_is_its_own_error() {
        let err = choose(Some(OsString::from("no/such/view.dll"))).unwrap_err();
        assert_eq!(err.message(), "CADACLYSM_VIEW=no/such/view.dll names nothing that exists");
    }

    #[test]
    fn a_cadaclysm_view_naming_a_directory_says_so() {
        let dir = std::env::temp_dir();
        let err = choose(Some(OsString::from(&dir))).unwrap_err();
        assert_eq!(err.message(), format!("CADACLYSM_VIEW={} is a directory, not a view library", dir.display()));
    }

    #[test]
    fn a_viewer_prints_its_name_path_and_version() {
        let text = format!("{:?}", fake::library());
        assert_eq!(text, r#"Library { name: "fake 1.0", path: "fake", abi_version: (1, 25) }"#);
    }

    #[test]
    fn no_library_names_the_places_searched_and_the_libraries_variable() {
        let found = "cadaclysm_terminal.dll not found. Looked in:\n    C:\\app\\cadaclysm_terminal.dll\n    \
                     C:\\lib\\cadaclysm_terminal.dll\nThe build gave no libraries of its own: offline\n\
                     Point CADACLYSM_TERMINAL_LIBRARY at it, or load it with its path first.";
        let m = no_library(found.to_string(), "terminal", TERMINAL_VARIABLE).message().to_string();
        assert!(m.starts_with("no view library: the terminal library was not found (searched: "), "{m}");
        assert_eq!(m.matches("CADACLYSM_TERMINAL_LIBRARY").count(), 1, "{m}");
        assert!(m.contains("C:\\app\\cadaclysm_terminal.dll, C:\\lib\\cadaclysm_terminal.dll)"), "{m}");
        assert!(m.contains("The build gave no libraries of its own: offline"), "{m}");
        assert!(!m.contains("load it with its path first"), "{m}");
        let wgpu = no_library("libcadaclysm_view.so not found. Looked in:\n    /app/libcadaclysm_view.so\n".to_string(), "wgpu", WGPU_VARIABLE);
        assert!(wgpu.message().starts_with("no view library: the wgpu library was not found (searched: /app/libcadaclysm_view.so)"), "{}", wgpu.message());
        assert!(wgpu.message().contains("set CADACLYSM_VIEW_LIBRARY to it"), "{}", wgpu.message());
        // Set and wrong is a broken library, said as the loader says it.
        let set = "CADACLYSM_VIEW_LIBRARY=x names nothing that exists";
        assert_eq!(no_library(set.to_string(), "wgpu", WGPU_VARIABLE).message(), set);
    }

    #[test]
    fn only_a_library_calling_itself_cadaclysm_terminal_is_the_terminal() {
        assert!(!fake::library().is_terminal());
    }

    /// Needs the real wgpu library (`CADACLYSM_VIEW_LIBRARY`); skips without it unless
    /// `CADACLYSM_REQUIRE_WGPU` is set.
    #[test]
    fn use_wgpu_loads_cadaclysm_view() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let before = *lock(&CURRENT);
        let library = match use_wgpu() {
            Ok(library) => library,
            Err(err) => return skip_wgpu(err),
        };
        assert!(library.name().starts_with("cadaclysm-view "), "{}", library.name());
        assert!(!library.is_terminal());
        assert!(std::ptr::eq(current().unwrap(), library));
        // Colour text is the real library's own parser (1.5).
        let purple = library.parse_colour("RebeccaPurple").unwrap();
        assert_eq!(purple.map(|c| (c * 255.0).round()), [102.0, 51.0, 153.0]);
        let err = library.rgb(Colour::from("blurple")).unwrap_err();
        assert!(err.message().contains("not 'blurple'"), "{}", err.message());
        *lock(&CURRENT) = before;
    }

    #[test]
    fn the_current_viewer_is_the_one_made_current_last() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let before = *lock(&CURRENT);
        let a: &'static Library = Box::leak(Box::new(fake::library()));
        let b: &'static Library = Box::leak(Box::new(fake::library()));
        make_current(a);
        assert!(std::ptr::eq(current().unwrap(), a));
        make_current(b);
        assert!(std::ptr::eq(current().unwrap(), b));
        // No later test in this process draws into a fake left current.
        *lock(&CURRENT) = before;
    }

    /// Needs the real terminal library (`CADACLYSM_TERMINAL_LIBRARY`); skips without it.
    #[test]
    fn naming_a_loaded_library_again_reuses_it() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let path = match terminal_library() {
            Ok(path) => path,
            Err(err) => return skip(err),
        };
        let first = use_library(&path).expect("the terminal library loads");
        assert!(first.name().starts_with("cadaclysm-terminal "), "{}", first.name());
        assert!(first.is_terminal());
        assert_eq!(first.abi_version().0, 1);
        assert_eq!(first.path(), canonical(&path));
        let again = use_library(&path).unwrap();
        assert!(std::ptr::eq(first, again), "a second use_library opened a second copy");
        // The same file named another way is the same library.
        let other = path.parent().unwrap().join(".").join(path.file_name().unwrap());
        assert!(std::ptr::eq(use_library(&other).unwrap(), first), "{} opened a second copy", other.display());
        assert!(std::ptr::eq(use_terminal().unwrap(), first));
    }

    #[test]
    fn a_file_that_is_not_a_view_library_is_refused_by_name() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // The kernel library is a real shared library with no cadaclysm_view_* in it.
        let path = match crate::blacksmith::sys::find_library() {
            Ok(path) => path,
            Err(err) => {
                eprintln!("skipped: {err}");
                return;
            }
        };
        let err = use_library(&path).expect_err("the kernel is not a view library");
        assert!(err.message().contains("not a view library"), "{}", err.message());
        assert!(err.message().contains("cadaclysm_view_abi_version"), "{}", err.message());
    }

    /// The terminal viewer really draws: this test runs its own binary again, as a child
    /// running only `draws_in_a_child`, and reads what the child wrote to stdout -- the
    /// viewer writes to file descriptor 1 itself, past the test harness's capture.
    #[test]
    fn the_terminal_viewer_draws_half_blocks() {
        if terminal_library().is_err() || crate::blacksmith::Solid::cuboid(1.0, 1.0, 1.0).is_err() {
            return skip("needs the terminal and kernel libraries");
        }
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["view::tests::draws_in_a_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env("CADACLYSM_VIEW_CHILD", "1")
            .output()
            .expect("the test binary runs again");
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "the child failed: {stdout}\n{}", String::from_utf8_lossy(&out.stderr));
        assert!(stdout.contains("\u{2580}"), "no half block in: {stdout:?}");
        // The background is half blocks too (30;30;30): a colour other than it is the cube.
        let drawn = stdout.split("\x1b[38;2;").skip(1).any(|s| !s.starts_with("30;30;30"));
        assert!(drawn, "only background in: {stdout:?}");
    }

    #[test]
    #[ignore = "run by the_terminal_viewer_draws_half_blocks, in a child process"]
    fn draws_in_a_child() {
        if std::env::var_os("CADACLYSM_VIEW_CHILD").is_none() {
            return;
        }
        let cube = crate::blacksmith::Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        use_terminal().unwrap();
        cube.show(&ViewOptions { hint: Some("blocks".into()), width: 64, height: 32, ..ViewOptions::default() }).unwrap();
    }

    /// `objects::aim`'s `RADIANS_PER_PIXEL`/`ZOOM_PER_STEP` mirror cadaclysm-view's own
    /// constants; the fake uses the same numbers, so only the real library tells when they
    /// drift. Off a terminal `run` returns at once, with the camera `view(az 30, el 20)`
    /// aimed -- once at the fit and once at twice the zoom, half the distance. The child
    /// is `aims_in_a_child`, as for `the_terminal_viewer_draws_half_blocks`.
    #[test]
    fn the_terminal_viewer_hands_back_the_camera_it_was_aimed_at() {
        if terminal_library().is_err() || crate::blacksmith::Solid::cuboid(1.0, 1.0, 1.0).is_err() {
            return skip("needs the terminal and kernel libraries");
        }
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["view::tests::aims_in_a_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env("CADACLYSM_VIEW_CHILD", "1")
            .output()
            .expect("the test binary runs again");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(out.status.success(), "the child failed: {stderr}");
        let cameras: Vec<Vec<f64>> = stderr
            .lines()
            .filter_map(|l| l.strip_prefix("camera "))
            .map(|l| l.split(' ').map(|x| x.parse().unwrap()).collect())
            .collect();
        assert_eq!(cameras.len(), 2, "{stderr}");
        for c in &cameras {
            assert!((c[0] - 30.0).abs() < 0.5 && (c[1] - 20.0).abs() < 0.5, "{stderr}");
        }
        assert!((cameras[1][2] / cameras[0][2] - 0.5).abs() < 0.01, "{stderr}");
    }

    #[test]
    #[ignore = "run by the_terminal_viewer_hands_back_the_camera_it_was_aimed_at, in a child process"]
    fn aims_in_a_child() {
        if std::env::var_os("CADACLYSM_VIEW_CHILD").is_none() {
            return;
        }
        let cube = crate::blacksmith::Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        use_terminal().unwrap();
        for zoom in [None, Some(2.0)] {
            let options = ViewOptions {
                azimuth: Some(30.0),
                elevation: Some(20.0),
                zoom,
                hint: Some("blocks".into()),
                width: 64,
                height: 32,
                ..ViewOptions::default()
            };
            let c = cube.view(&options).unwrap();
            let distance = c.eye.iter().zip(c.target).map(|(e, t)| f64::from(e - t).powi(2)).sum::<f64>().sqrt();
            eprintln!("camera {} {} {distance}", c.azimuth, c.elevation);
        }
    }
}
