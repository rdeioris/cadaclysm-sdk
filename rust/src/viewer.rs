//! Drawing through a viewer library: `solid.show(..)`, `scene.view(..)`.
//!
//! A viewer is a shared library implementing `cadaclysm_viewer.h`. The SDK bundles one,
//! the terminal viewer (`cadaclysm_terminal`), which draws with sixel, the kitty graphics
//! protocol or coloured half blocks; a library that opens a window can implement the same
//! contract, and the same calls then draw there.

pub mod sys;

mod options;

pub(crate) mod draw;

pub use options::{Camera, ViewOptions};

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use libloading::Library;

use crate::{loader, text, Error, Result};

/// The variable naming the bundled terminal library (the library, or its directory).
const TERMINAL_VARIABLE: &str = "CADACLYSM_TERMINAL_LIBRARY";

/// A loaded viewer library. Loaded once per path per process and never unloaded, so the
/// `&'static Viewer` that [`use_library`] and [`current`] hand out stays valid.
pub struct Viewer {
    api: sys::Api,
    name: String,
    path: PathBuf,
    version: u32,
    // Never dropped: every pointer in `api` points into it.
    _library: Option<Library>,
}

impl std::fmt::Debug for Viewer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Viewer")
            .field("name", &self.name)
            .field("path", &self.path)
            .field("abi_version", &self.abi_version())
            .finish()
    }
}

impl Viewer {
    /// What the library calls itself -- `cadaclysm_viewer_name()`, e.g.
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

    pub(crate) fn api(&self) -> &sys::Api {
        &self.api
    }

    fn from_api(api: sys::Api, path: PathBuf, library: Option<Library>) -> Result<Viewer> {
        let version = unsafe { (api.cadaclysm_viewer_abi_version)() };
        if version >> 16 != sys::CADACLYSM_VIEWER_ABI_MAJOR {
            return Err(Error::new(format!(
                "{}: viewer ABI {}.{}, this SDK needs {}.x",
                path.display(),
                version >> 16,
                version & 0xFFFF,
                sys::CADACLYSM_VIEWER_ABI_MAJOR
            )));
        }
        let name = unsafe { text((api.cadaclysm_viewer_name)()) };
        Ok(Viewer { api, name, path, version, _library: library })
    }

    fn open(path: &Path) -> Result<Viewer> {
        // SAFETY: loading runs the library's initialisers and every symbol is then read as
        // the header declares it -- the contract of loading a viewer library at all.
        let library = unsafe { Library::new(path) }
            .map_err(|e| Error::new(format!("{}: could not load the viewer library: {e}", path.display())))?;
        let api = unsafe { sys::Api::bind(&library, path) }.map_err(|_| {
            let missing = sys::ENTRY_POINTS
                .iter()
                .find(|name| unsafe { library.get::<*const ()>(format!("{name}\0").as_bytes()) }.is_err())
                .copied()
                .unwrap_or("an entry point");
            Error::new(format!("{}: not a viewer library (no {missing})", path.display()))
        })?;
        Viewer::from_api(api, canonical(path), Some(library))
    }
}

static LOADED: Mutex<Vec<&'static Viewer>> = Mutex::new(Vec::new());
static CURRENT: Mutex<Option<&'static Viewer>> = Mutex::new(None);

/// A poisoned lock still holds a consistent list: nothing panics while holding one.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `path` absolute with its links resolved, so one file named two ways (or a relative
/// path named again after the working directory moved) is one key; as given when it
/// cannot be resolved.
fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// The viewer at `path`, loading it the first time it is named.
fn loaded(path: &Path) -> Result<&'static Viewer> {
    let wanted = canonical(path);
    let mut all = lock(&LOADED);
    if let Some(viewer) = all.iter().find(|v| v.path == wanted) {
        return Ok(viewer);
    }
    let viewer: &'static Viewer = Box::leak(Box::new(Viewer::open(path)?));
    all.push(viewer);
    Ok(viewer)
}

fn make_current(viewer: &'static Viewer) -> &'static Viewer {
    *lock(&CURRENT) = Some(viewer);
    viewer
}

/// Draw with the viewer library at `path` from now on. A library already loaded is
/// reused, not opened again. Returns it.
pub fn use_library(path: impl AsRef<Path>) -> Result<&'static Viewer> {
    Ok(make_current(loaded(path.as_ref())?))
}

/// Draw with the terminal viewer bundled with the SDK from now on, whatever was in use.
pub fn use_terminal() -> Result<&'static Viewer> {
    use_library(terminal_library()?)
}

/// The viewer `show` and `view` draw with: the last [`use_library`] or [`use_terminal`];
/// else the library `CADACLYSM_VIEWER` names; else the bundled terminal viewer. A failure
/// is not remembered -- the next call looks again.
pub fn current() -> Result<&'static Viewer> {
    if let Some(viewer) = *lock(&CURRENT) {
        return Ok(viewer);
    }
    let viewer = loaded(&choose(std::env::var_os("CADACLYSM_VIEWER"), terminal_library)?)?;
    // A `use_library` on another thread since the check above wins: the default only
    // fills an empty slot.
    Ok(*lock(&CURRENT).get_or_insert(viewer))
}

/// `CADACLYSM_VIEWER` when set and not empty (a file that must exist), else `terminal()`.
fn choose(named: Option<OsString>, terminal: impl FnOnce() -> Result<PathBuf>) -> Result<PathBuf> {
    match named.filter(|value| !value.is_empty()) {
        Some(value) => {
            let path = PathBuf::from(value);
            if path.is_file() {
                Ok(path)
            } else if path.is_dir() {
                Err(Error::new(format!("CADACLYSM_VIEWER={} is a directory, not a viewer library", path.display())))
            } else {
                Err(Error::new(format!("CADACLYSM_VIEWER={} names nothing that exists", path.display())))
            }
        }
        None => terminal(),
    }
}

/// Where the bundled terminal viewer is, without loading it: `CADACLYSM_TERMINAL_LIBRARY`
/// (the library or its directory) when set; else the search the reader and kernel
/// libraries get -- beside the executable, where the build downloaded, a `lib/` or a
/// `target/release`/`target/debug` above the executable or the working directory.
pub fn terminal_library() -> Result<PathBuf> {
    loader::find(&loader::file_name("cadaclysm_terminal"), TERMINAL_VARIABLE).map_err(no_viewer)
}

/// The error for `loader::find`'s `message` about the terminal library: the places it
/// searched (its indented lines) and any download error, in the viewer's words -- not
/// the loader's closing advice, which names one variable of the two.
fn no_viewer(message: String) -> Error {
    if message.starts_with(TERMINAL_VARIABLE) {
        // The variable is set and wrong: a broken viewer, not a missing one.
        return Error::new(message);
    }
    let searched: Vec<&str> = message.lines().filter_map(|line| line.strip_prefix("    ")).collect();
    let mut text = format!(
        "no viewer: the terminal viewer library was not found (searched: {}) -- set {TERMINAL_VARIABLE} \
         to it, or CADACLYSM_VIEWER to another viewer",
        searched.join(", ")
    );
    if let Some(download) = message.lines().find(|line| line.starts_with("The build did not download")) {
        text.push('\n');
        text.push_str(download);
    }
    Error::new(text)
}

#[cfg(test)]
pub(crate) mod fake;

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    /// Serialises the tests that set the process-wide current viewer.
    static CURRENT_LOCK: Mutex<()> = Mutex::new(());

    /// A test that cannot run without a real library skips -- unless
    /// `CADACLYSM_REQUIRE_VIEWER` is set, as CI sets it, where a skip would pass having
    /// checked nothing.
    fn skip(why: impl std::fmt::Display) {
        if std::env::var_os("CADACLYSM_REQUIRE_VIEWER").is_some_and(|v| !v.is_empty()) {
            panic!("CADACLYSM_REQUIRE_VIEWER is set, but: {why}");
        }
        eprintln!("skipped: {why}");
    }

    #[test]
    fn a_viewer_reports_its_name_and_version() {
        let v = fake::viewer();
        assert_eq!(v.name(), "fake 1.0");
        assert_eq!(v.abi_version(), (1, 0));
        assert_eq!(v.path(), Path::new("fake"));
    }

    #[test]
    fn another_abi_major_is_refused_with_both_versions() {
        fake::abi((2 << 16) | 3);
        let err = Viewer::from_api(fake::api(), PathBuf::from("v2.dll"), None).expect_err("ABI 2 refused");
        fake::abi(1 << 16);
        assert_eq!(err.message(), "v2.dll: viewer ABI 2.3, this SDK needs 1.x");
    }

    #[test]
    fn a_minor_version_is_accepted() {
        fake::abi((1 << 16) | 7);
        let v = Viewer::from_api(fake::api(), PathBuf::from("v1.7"), None);
        fake::abi(1 << 16);
        assert_eq!(v.expect("1.7 is 1.x").abi_version(), (1, 7));
    }

    #[test]
    fn cadaclysm_viewer_wins_over_the_terminal() {
        let exe = std::env::current_exe().unwrap();
        let chosen = choose(Some(OsString::from(&exe)), || panic!("the terminal was not asked for")).unwrap();
        assert_eq!(chosen, exe);
    }

    #[test]
    fn an_empty_cadaclysm_viewer_falls_back_to_the_terminal() {
        let chosen = choose(Some(OsString::new()), || Ok(PathBuf::from("terminal"))).unwrap();
        assert_eq!(chosen, PathBuf::from("terminal"));
        let chosen = choose(None, || Ok(PathBuf::from("terminal"))).unwrap();
        assert_eq!(chosen, PathBuf::from("terminal"));
    }

    #[test]
    fn a_cadaclysm_viewer_naming_nothing_is_its_own_error() {
        let err = choose(Some(OsString::from("no/such/viewer.dll")), || Ok(PathBuf::from("terminal"))).unwrap_err();
        assert_eq!(err.message(), "CADACLYSM_VIEWER=no/such/viewer.dll names nothing that exists");
    }

    #[test]
    fn a_cadaclysm_viewer_naming_a_directory_says_so() {
        let dir = std::env::temp_dir();
        let err = choose(Some(OsString::from(&dir)), || Ok(PathBuf::from("terminal"))).unwrap_err();
        assert_eq!(err.message(), format!("CADACLYSM_VIEWER={} is a directory, not a viewer library", dir.display()));
    }

    #[test]
    fn a_viewer_prints_its_name_path_and_version() {
        let text = format!("{:?}", fake::viewer());
        assert_eq!(text, r#"Viewer { name: "fake 1.0", path: "fake", abi_version: (1, 0) }"#);
    }

    #[test]
    fn no_viewer_names_the_places_searched_and_the_two_variables_once() {
        let found = "cadaclysm_terminal.dll not found. Looked in:\n    C:\\app\\cadaclysm_terminal.dll\n    \
                     C:\\lib\\cadaclysm_terminal.dll\nThe build did not download the libraries: offline\n\
                     Point CADACLYSM_TERMINAL_LIBRARY at it, or load it with its path first.";
        let m = no_viewer(found.to_string()).message().to_string();
        assert!(m.starts_with("no viewer: the terminal viewer library was not found (searched: "), "{m}");
        assert_eq!(m.matches("CADACLYSM_TERMINAL_LIBRARY").count(), 1, "{m}");
        assert_eq!(m.matches("CADACLYSM_VIEWER").count(), 1, "{m}");
        assert!(m.contains("C:\\app\\cadaclysm_terminal.dll, C:\\lib\\cadaclysm_terminal.dll)"), "{m}");
        assert!(m.contains("The build did not download the libraries: offline"), "{m}");
        assert!(!m.contains("load it with its path first"), "{m}");
        // Set and wrong is a broken viewer, said as the loader says it.
        let set = "CADACLYSM_TERMINAL_LIBRARY=x names nothing that exists";
        assert_eq!(no_viewer(set.to_string()).message(), set);
    }

    #[test]
    fn the_current_viewer_is_the_one_made_current_last() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let before = *lock(&CURRENT);
        let a: &'static Viewer = Box::leak(Box::new(fake::viewer()));
        let b: &'static Viewer = Box::leak(Box::new(fake::viewer()));
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
    fn a_file_that_is_not_a_viewer_is_refused_by_name() {
        let _guard = CURRENT_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // The kernel library is a real shared library with no cadaclysm_viewer_* in it.
        let path = match crate::blacksmith::sys::find_library() {
            Ok(path) => path,
            Err(err) => {
                eprintln!("skipped: {err}");
                return;
            }
        };
        let err = use_library(&path).expect_err("the kernel is not a viewer");
        assert!(err.message().contains("not a viewer library"), "{}", err.message());
        assert!(err.message().contains("cadaclysm_viewer_abi_version"), "{}", err.message());
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
            .args(["viewer::tests::draws_in_a_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env("CADACLYSM_VIEWER_CHILD", "1")
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
        if std::env::var_os("CADACLYSM_VIEWER_CHILD").is_none() {
            return;
        }
        let mut cube = crate::blacksmith::Solid::cuboid(1.0, 1.0, 1.0).unwrap();
        use_terminal().unwrap();
        cube.show(&ViewOptions { hint: Some("blocks".into()), width: 64, height: 32, ..ViewOptions::default() }).unwrap();
    }
}
