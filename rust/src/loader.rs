//! Opening a cadaclysm library at run time: finding the file, binding its entry points
//! once per process. Shared by the reader ([`crate::sys`]) and the kernel
//! ([`crate::blacksmith::sys`]), each with its own library, its own environment
//! variable and its own function table.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use libloading::Library;

/// Declares a function table: one field per entry point, bound by name when the
/// library loads, plus the list of names it binds. Every entry point is bound up
/// front, so a library older than this crate is refused at load with the name it
/// lacks, rather than at some later call.
macro_rules! entry_points {
    ($api:ident, $names:ident; $(fn $name:ident($($arg:ident: $ty:ty),*) $(-> $ret:ty)?;)*) => {
        /// Every entry point of the header this crate calls, as function pointers
        /// into the loaded library.
        #[allow(non_snake_case)]
        pub struct $api {
            $(pub $name: unsafe extern "C" fn($($ty),*) $(-> $ret)?,)*
        }

        /// The names the table binds, in declaration order.
        pub const $names: &[&str] = &[$(stringify!($name)),*];

        impl $api {
            /// # Safety
            /// `library` must be the cadaclysm library this table describes: each
            /// symbol is read as the signature declared here, and nothing can check
            /// that it is one.
            pub(crate) unsafe fn bind(library: &::libloading::Library, path: &::std::path::Path) -> Result<$api, String> {
                Ok($api {
                    $($name: *library
                        .get::<unsafe extern "C" fn($($ty),*) $(-> $ret)?>(
                            concat!(stringify!($name), "\0").as_bytes(),
                        )
                        .map_err(|_| $crate::loader::stale(path, stringify!($name), $names.len()))?,)*
                })
            }
        }
    };
}

pub(crate) use entry_points;

pub(crate) fn stale(path: &Path, name: &str, count: usize) -> String {
    with_build_note(
        format!(
            "{} has no {name}: the library is older than this copy of cadaclysm-sdk, which \
             binds {count} entry points. Use the library from the same release as the crate.",
            path.display()
        ),
        BUILD_ERROR,
    )
}

/// Why the build gave no libraries of its own (the `download` feature: a failed download,
/// or a failed build from the source tree), baked in by build.rs.
pub(crate) const BUILD_ERROR: Option<&str> = option_env!("CADACLYSM_SDK_DOWNLOAD_ERROR");

/// The first words of [`build_note`]'s line, which the view looks for in a loader message.
pub(crate) const BUILD_NOTE: &str = "The build gave no libraries of its own";

/// The line saying why the build gave no libraries, for a message about a library that is
/// missing, or found and too old -- an older one left beside the binaries by an earlier
/// build is exactly what a program finds when this build's own failed.
pub(crate) fn build_note(reason: &str) -> String {
    format!("{BUILD_NOTE}: {reason}")
}

/// `message`, with [`build_note`] on a line of its own after it when there is a `reason`.
pub(crate) fn with_build_note(message: String, reason: Option<&str>) -> String {
    match reason {
        Some(reason) => format!("{message}\n{}", build_note(reason)),
        None => message,
    }
}

/// The platform's file name for the library whose stem is `stem`: `cadaclysm_capi.dll`,
/// `libcadaclysm_capi.so`, `libcadaclysm_capi.dylib`.
pub(crate) fn file_name(stem: &str) -> String {
    if cfg!(windows) {
        format!("{stem}.dll")
    } else if cfg!(target_os = "macos") {
        format!("lib{stem}.dylib")
    } else {
        format!("lib{stem}.so")
    }
}

/// Where the library named `name` is, without loading it -- or, where nothing was
/// found, a message naming every place that was looked in.
///
/// `env` first (the library itself or its directory); then beside the running
/// executable; then where the build downloaded it (the `download` feature); then a
/// `lib/` directory in any ancestor of the executable or of the working directory (the
/// SDK's layout); then a `target/release` or `target/debug` in any of those ancestors
/// (the repository's layout). No other variable is read and the system's own search is
/// not consulted, so a stray copy elsewhere on `PATH` is never picked up by accident.
pub(crate) fn find(name: &str, env: &str) -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os(env).filter(|v| !v.is_empty()) {
        let given = PathBuf::from(&value);
        let candidate = if given.is_dir() { given.join(name) } else { given };
        return if candidate.is_file() {
            Ok(candidate)
        } else {
            Err(format!("{env}={} names nothing that exists", display(&value)))
        };
    }

    let mut starts = Vec::new();
    if let Some(dir) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        starts.push(dir);
    }
    if let Ok(dir) = std::env::current_dir() {
        starts.push(dir);
    }
    let mut searched: Vec<PathBuf> = starts.iter().take(1).map(|dir| dir.join(name)).collect();
    // What the build downloaded (the `download` feature): this crate's own release.
    if let Some(bundled) = option_env!("CADACLYSM_SDK_BUNDLED") {
        searched.push(Path::new(bundled).join(name));
    }
    for start in &starts {
        searched.extend(start.ancestors().map(|dir| dir.join("lib").join(name)));
    }
    for start in &starts {
        for dir in start.ancestors() {
            searched.extend(["release", "debug"].map(|profile| dir.join("target").join(profile).join(name)));
        }
    }
    if let Some(found) = searched.iter().find(|candidate| candidate.is_file()) {
        return Ok(found.clone());
    }
    let mut message = format!("{name} not found. Looked in:\n");
    for candidate in &searched {
        message.push_str(&format!("    {}\n", candidate.display()));
    }
    if let Some(reason) = BUILD_ERROR {
        message.push_str(&build_note(reason));
        message.push('\n');
    }
    message.push_str(&format!("Point {env} at it, or load it with its path first."));
    Err(message)
}

fn display(value: &OsString) -> String {
    value.to_string_lossy().into_owned()
}

struct Loaded<A> {
    api: A,
    path: PathBuf,
    // Never dropped: every function pointer in `api` points into it, and a static
    // outlives any caller that could still hold one.
    _library: Library,
}

/// One library, loaded at most once per process.
pub(crate) struct Loader<A: 'static> {
    stem: &'static str,
    env: &'static str,
    bind: unsafe fn(&Library, &Path) -> Result<A, String>,
    // The table's entry points: the first finds the file a copy already in the process
    // was loaded from.
    names: &'static [&'static str],
    loaded: OnceLock<Loaded<A>>,
    // Serialises the first load, so two threads racing to it open the library once.
    // Only a success is kept: a failed load is tried again on the next call, so a
    // program can set the variable or load with a path after a first miss.
    loading: Mutex<()>,
}

impl<A: 'static> Loader<A> {
    pub(crate) const fn new(
        stem: &'static str,
        env: &'static str,
        bind: unsafe fn(&Library, &Path) -> Result<A, String>,
        names: &'static [&'static str],
    ) -> Loader<A> {
        Loader { stem, env, bind, names, loaded: OnceLock::new(), loading: Mutex::new(()) }
    }

    pub(crate) fn file_name(&self) -> String {
        file_name(self.stem)
    }

    pub(crate) fn find(&self) -> Result<PathBuf, String> {
        find(&self.file_name(), self.env)
    }

    /// Load the library at `path` and bind every entry point, once. Without a `path`, a
    /// library of this file name the process already holds -- one a Python module or
    /// another library loaded -- is bound rather than a second copy beside it, and only
    /// where there is none is one loaded from where [`Loader::find`] finds it. A second
    /// call naming the library already bound is a no-op; naming another one is an error,
    /// since two copies cannot share a handle or a license.
    pub(crate) fn load(&'static self, path: Option<&Path>) -> Result<&'static A, String> {
        self.load_with(path, false)
    }

    /// Bind the copy of the library the process already holds, found by its file name as
    /// a viewer finds it. An error where the process holds none, or where this crate
    /// already bound another copy.
    pub(crate) fn use_loaded(&'static self) -> Result<&'static A, String> {
        self.load_with(None, true)
    }

    fn load_with(&'static self, path: Option<&Path>, loaded_only: bool) -> Result<&'static A, String> {
        if let Some(loaded) = self.loaded.get() {
            return self.check_bound(loaded, path, loaded_only);
        }
        let _guard = self.loading.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(loaded) = self.loaded.get() {
            return self.check_bound(loaded, path, loaded_only);
        }
        let held = if path.is_none() { self.in_process() } else { None };
        // SAFETY: loading runs the library's initialisers, and every symbol is then
        // read as the signature the table declares. Both are the contract of loading
        // a cadaclysm library at all; nothing on this side can check `path` is one.
        let loaded = unsafe {
            let (library, path) = match (held, path) {
                (Some(held), _) => held,
                (None, _) if loaded_only => return Err(self.none_held()),
                (None, given) => {
                    let path = match given {
                        Some(path) => path.to_path_buf(),
                        None => self.find()?,
                    };
                    (Library::new(&path).map_err(|e| format!("{}: {e}", path.display()))?, path)
                }
            };
            let api = (self.bind)(&library, &path)?;
            Loaded { api, path, _library: library }
        };
        Ok(&self.loaded.get_or_init(|| loaded).api)
    }

    /// [`check_same`], and for [`Loader::use_loaded`] that the copy bound is the one the
    /// process holds under this file name.
    fn check_bound(&'static self, loaded: &'static Loaded<A>, path: Option<&Path>, loaded_only: bool) -> Result<&'static A, String> {
        if loaded_only {
            match self.in_process() {
                Some((_, held)) if same_file(&held, &loaded.path) => {}
                Some((_, held)) => {
                    return Err(format!(
                        "the library is already loaded from {}, so the copy at {} cannot be bound",
                        loaded.path.display(),
                        held.display()
                    ))
                }
                None => return Err(self.none_held()),
            }
        }
        check_same(loaded, path)
    }

    fn none_held(&self) -> String {
        format!("no {} is loaded in this process", self.file_name())
    }

    /// The library of this file name the process already holds, with the file it was
    /// loaded from (its bare name where the system cannot say). Loads nothing.
    fn in_process(&self) -> Option<(Library, PathBuf)> {
        let name = self.file_name();
        let (library, path) = held(&name, self.names.first().copied().unwrap_or_default())?;
        Some((library, path.unwrap_or_else(|| PathBuf::from(&name))))
    }

    /// The path the library was loaded from, or `None` before anything loaded it.
    pub(crate) fn loaded_path(&'static self) -> Option<&'static Path> {
        self.loaded.get().map(|loaded| loaded.path.as_path())
    }
}

/// The library of the file name `name` if the process already holds one, and the file it
/// came from: Windows' module list, or `dlopen(name, RTLD_NOLOAD)`, which matches a loaded
/// library's soname (a dylib's install name), as the View's own lookup does. Nothing is
/// loaded. The file is read off the module (Windows) or the address of its symbol `probe`.
#[cfg(windows)]
fn held(name: &str, _probe: &str) -> Option<(Library, Option<PathBuf>)> {
    use std::os::windows::ffi::OsStringExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleFileNameW(module: isize, name: *mut u16, size: u32) -> u32;
    }
    let module = libloading::os::windows::Library::open_already_loaded(name).ok()?.into_raw();
    let mut buffer = vec![0u16; 32768];
    // SAFETY: `module` is a module handle this call holds a reference on.
    let length = unsafe { GetModuleFileNameW(module, buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    let path = (length > 0 && length < buffer.len()).then(|| PathBuf::from(OsString::from_wide(&buffer[..length])));
    // SAFETY: the handle `into_raw` gave up, taken back to be released on drop.
    Some((unsafe { libloading::os::windows::Library::from_raw(module) }.into(), path))
}

#[cfg(unix)]
fn held(name: &str, probe: &str) -> Option<(Library, Option<PathBuf>)> {
    use std::ffi::{c_char, c_int, c_void, CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    #[repr(C)]
    struct DlInfo {
        fname: *const c_char,
        fbase: *mut c_void,
        sname: *const c_char,
        saddr: *mut c_void,
    }
    extern "C" {
        fn dladdr(address: *const c_void, info: *mut DlInfo) -> c_int;
    }
    // RTLD_NOLOAD, which libloading does not name: glibc's and bionic's 4, Apple's 0x10.
    const RTLD_NOLOAD: c_int = if cfg!(target_vendor = "apple") { 0x10 } else { 0x4 };
    // SAFETY: with RTLD_NOLOAD nothing is loaded, so no initialiser runs.
    let library = unsafe { libloading::os::unix::Library::open(Some(name), RTLD_NOLOAD | libloading::os::unix::RTLD_LAZY) }.ok()?;
    let symbol = format!("{probe}\0");
    let path = unsafe { library.get::<*const c_void>(symbol.as_bytes()) }.ok().and_then(|address| {
        let mut info = DlInfo { fname: std::ptr::null(), fbase: std::ptr::null_mut(), sname: std::ptr::null(), saddr: std::ptr::null_mut() };
        // SAFETY: `address` is a symbol of a loaded library; dladdr only reads it.
        let found = unsafe { dladdr(*address, &mut info) } != 0 && !info.fname.is_null();
        found.then(|| PathBuf::from(OsStr::from_bytes(unsafe { CStr::from_ptr(info.fname) }.to_bytes())))
    });
    Some((library.into(), path))
}

#[cfg(not(any(windows, unix)))]
fn held(_name: &str, _probe: &str) -> Option<(Library, Option<PathBuf>)> {
    None
}

fn check_same<A>(loaded: &'static Loaded<A>, path: Option<&Path>) -> Result<&'static A, String> {
    match path {
        Some(path) if !same_file(path, &loaded.path) => Err(format!(
            "the library is already loaded from {}, so {} cannot be",
            loaded.path.display(),
            path.display()
        )),
        _ => Ok(&loaded.api),
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_build_error_follows_the_message_on_a_line_of_its_own() {
        let reason = "they were not downloaded: curl could not fetch x";
        assert_eq!(with_build_note("m".to_string(), None), "m");
        assert_eq!(
            with_build_note("m".to_string(), Some(reason)),
            "m\nThe build gave no libraries of its own: they were not downloaded: curl could not fetch x"
        );
    }
}
