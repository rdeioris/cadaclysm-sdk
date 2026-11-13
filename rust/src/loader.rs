//! Opening a cadaclysm library at run time: finding the file, binding its entry points
//! once per process. Shared by the reader ([`crate::sys`]) and the kernel
//! ([`crate::blacksmith::sys`]), each with its own names to look for, its own
//! environment variables and its own function table.
//!
//! One library of any flavour serves both: the single library's flavours (`cadaclysm`,
//! `cadaclysm_kernel_reader`, `cadaclysm_kernel`, `cadaclysm_reader`) are looked for
//! first, then the separate library of earlier releases. A flavour binds what it has;
//! an entry point it leaves out is refused by name where the crate would call it
//! ([`Flavour`]), and a flavour without a half at all is refused when that half loads.

use std::ffi::{c_char, CStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[cfg(not(target_arch = "wasm32"))]
pub(crate) use libloading::Library;
#[cfg(target_arch = "wasm32")]
pub(crate) use self::no_library::Library;

/// Declares a function table: one field per entry point, bound by name when the
/// library loads, plus the list of names it binds. Every entry point is bound up
/// front, so a separate library older than this crate is refused at load with the
/// name it lacks, rather than at some later call. A flavour of the single library
/// binds what it has: an entry point it leaves out is listed in the table's
/// [`Flavour`], refused by name ([`Flavour::check`]) where the crate calls it, and
/// bound to a stand-in that stops the process saying so should anything call it
/// unchecked -- never to an address that is not a function.
///
/// The kernel's table is declared `web; Api, ENTRY_POINTS; ...`: on wasm32 it is also
/// filled from the web package (`Api::from_shim`, the generated adapters in
/// [`crate::web`]'s shim), which have exactly the signatures declared here.
macro_rules! entry_points {
    (web; $api:ident, $names:ident; $(fn $name:ident($($arg:ident: $ty:ty),*) $(-> $ret:ty)?;)*) => {
        $crate::loader::entry_points! { $api, $names; $(fn $name($($arg: $ty),*) $(-> $ret)?;)* }

        #[cfg(target_arch = "wasm32")]
        impl $api {
            /// The table over the web package: each entry the shim's adapter of that name.
            pub(crate) fn from_shim() -> $api {
                // The web package is one build of the whole kernel: no flavour leaves anything out.
                $api { $($name: $crate::web::shim::$name,)* flavour: None }
            }
        }
    };
    ($api:ident, $names:ident; $(fn $name:ident($($arg:ident: $ty:ty),*) $(-> $ret:ty)?;)*) => {
        /// Every entry point of the header this crate calls, as function pointers
        /// into the loaded library.
        #[allow(non_snake_case)]
        pub struct $api {
            $(pub $name: unsafe extern "C" fn($($ty),*) $(-> $ret)?,)*
            /// Which flavour of the single library this is, and what it leaves out;
            /// `None` for a separate library of an earlier release.
            pub(crate) flavour: Option<$crate::loader::Flavour>,
        }

        /// The names the table binds, in declaration order.
        pub const $names: &[&str] = &[$(stringify!($name)),*];

        impl $api {
            /// # Safety
            /// `library` must be the cadaclysm library this table describes: each
            /// symbol is read as the signature declared here, and nothing can check
            /// that it is one.
            #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
            pub(crate) unsafe fn bind(
                library: &$crate::loader::Library,
                path: &::std::path::Path,
                flavour: Option<(String, String)>,
            ) -> Result<$api, String> {
                let mut missing: Vec<&'static str> = Vec::new();
                let flavoured = flavour.is_some();
                Ok($api {
                    $($name: match library.get::<unsafe extern "C" fn($($ty),*) $(-> $ret)?>(
                        concat!(stringify!($name), "\0").as_bytes(),
                    ) {
                        Ok(symbol) => *symbol,
                        Err(_) if flavoured => {
                            missing.push(stringify!($name));
                            #[allow(non_snake_case)]
                            unsafe extern "C" fn $name($(_: $ty),*) $(-> $ret)? {
                                $crate::loader::reached_missing(stringify!($name))
                            }
                            $name
                        }
                        Err(_) => return Err($crate::loader::stale(path, stringify!($name), $names.len())),
                    },)*
                    flavour: flavour.map(|(name, features)| $crate::loader::Flavour { name, features, missing }),
                })
            }

            /// Which flavour of the single library this is, and what it leaves out; `None`
            /// for a separate library of an earlier release.
            pub fn flavour(&self) -> Option<&$crate::loader::Flavour> {
                self.flavour.as_ref()
            }

            /// `Ok` where entry point `name` is bound; the flavour's refusal, naming it,
            /// where this flavour leaves it out. Every call the flavours can leave out goes
            /// through this first.
            #[allow(dead_code)] // the view's table and the reader's have none to check
            pub(crate) fn require(&self, name: &str) -> Result<(), String> {
                match &self.flavour {
                    Some(flavour) => flavour.check(name),
                    None => Ok(()),
                }
            }
        }
    };
}

/// A flavour of the single library: its name and features, as `cadaclysm_flavour()` and
/// `cadaclysm_features()` answer, and the entry points of this crate's table it leaves out.
#[derive(Debug, Clone)]
pub struct Flavour {
    /// `"full"`, `"kernel-reader"`, `"kernel"` or `"reader"`.
    pub name: String,
    /// The features it was built with, comma-separated (`"nodes,kernel,bim"`).
    pub features: String,
    /// The table's entry points this flavour does not export.
    pub missing: Vec<&'static str>,
}

impl Flavour {
    /// Whether the features name `feature`.
    pub fn has(&self, feature: &str) -> bool {
        self.features.split(',').any(|f| f == feature)
    }

    /// `Ok`, or the refusal for entry point `name` where this flavour leaves it out:
    /// `<call>: not in this library's flavour ('<flavour>', features <features>); the
    /// full flavour has it`, the call named as the other errors name it.
    pub fn check(&self, name: &str) -> Result<(), String> {
        if !self.missing.contains(&name) {
            return Ok(());
        }
        let call = name.strip_prefix("cadaclysm_blacksmith_").or_else(|| name.strip_prefix("cadaclysm_")).unwrap_or(name);
        let features = if self.features.is_empty() { "none" } else { &self.features };
        Err(format!("{call}: not in this library's flavour ('{}', features {features}); the full flavour has it", self.name))
    }
}

/// The stand-in a flavour's missing entry point is bound to: reached only by a call that
/// skipped [`Flavour::check`], which is a bug in this crate, so it says which and stops.
pub(crate) fn reached_missing(name: &str) -> ! {
    eprintln!("cadaclysm-sdk: {name} called, but this library's flavour does not have it; the full flavour has it");
    std::process::abort()
}

/// `(flavour, features)` for one of the single library's flavours, or `None` for a separate
/// library of an earlier release, which exports neither call.
///
/// # Safety
/// `library` must be a cadaclysm library: both symbols are read as `const char *(void)`.
unsafe fn flavour_of(library: &Library) -> Option<(String, String)> {
    type Text = unsafe extern "C" fn() -> *const c_char;
    let flavour = library.get::<Text>(b"cadaclysm_flavour\0").ok()?;
    let features = library.get::<Text>(b"cadaclysm_features\0").ok()?;
    let read = |raw: *const c_char| if raw.is_null() { String::new() } else { CStr::from_ptr(raw).to_string_lossy().into_owned() };
    Some((read(flavour()), read(features())))
}

/// What one half of the crate needs of a library: the feature that carries it, its name in
/// a refusal, and the libraries to load instead.
pub(crate) struct Half {
    pub(crate) feature: &'static str,
    pub(crate) what: &'static str,
    pub(crate) instead: &'static str,
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

/// Where the library is, without loading it -- or, where nothing was found, a message
/// naming every place that was looked in. `names` are the files to look for, in order.
///
/// `envs` first, in order: each the library itself or its directory (the first of
/// `names` it holds). A later variable is a fallback that was another library's before
/// the single library -- `CADACLYSM_LIBRARY` for the kernel -- so where it names the
/// separate reader library, or a directory holding none of `names`, it is not for this
/// one and the search goes on. Then beside the running executable; then where the build
/// downloaded it (the `download` feature); then a `lib/` directory in any ancestor of the
/// executable or of the working directory (the SDK's layout); then a `target/release` or
/// `target/debug` in any of those ancestors (the repository's layout). Each place is
/// asked for every name in turn. No other variable is read and the system's own search is
/// not consulted, so a stray copy elsewhere on `PATH` is never picked up by accident.
pub(crate) fn find(names: &[String], envs: &[&str]) -> Result<PathBuf, String> {
    for (at, env) in envs.iter().enumerate() {
        let Some(value) = std::env::var_os(env).filter(|v| !v.is_empty()) else { continue };
        let given = PathBuf::from(&value);
        let fallback = at > 0;
        if given.is_dir() {
            if let Some(found) = names.iter().map(|name| given.join(name)).find(|c| c.is_file()) {
                return Ok(found);
            }
            if fallback {
                break;
            }
        } else if given.is_file() {
            let separate_reader = given.file_name().is_some_and(|n| n == file_name("cadaclysm_capi").as_str());
            if !(fallback && separate_reader) {
                return Ok(given);
            }
            break;
        }
        return Err(format!("{env}={} names nothing that exists", display(&value)));
    }

    let mut starts = Vec::new();
    if let Some(dir) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        starts.push(dir);
    }
    if let Ok(dir) = std::env::current_dir() {
        starts.push(dir);
    }
    let mut places: Vec<PathBuf> = starts.iter().take(1).cloned().collect();
    // What the build downloaded (the `download` feature): this crate's own release.
    if let Some(bundled) = option_env!("CADACLYSM_SDK_BUNDLED") {
        places.push(PathBuf::from(bundled));
    }
    for start in &starts {
        places.extend(start.ancestors().map(|dir| dir.join("lib")));
    }
    for start in &starts {
        for dir in start.ancestors() {
            places.extend(["release", "debug"].map(|profile| dir.join("target").join(profile)));
        }
    }
    let searched: Vec<PathBuf> = places.iter().flat_map(|place| names.iter().map(move |name| place.join(name))).collect();
    if let Some(found) = searched.iter().find(|candidate| candidate.is_file()) {
        return Ok(found.clone());
    }
    let mut message = format!("none of {} found. Looked in:\n", names.join(", "));
    for candidate in &searched {
        message.push_str(&format!("    {}\n", candidate.display()));
    }
    if let Some(reason) = BUILD_ERROR {
        message.push_str(&build_note(reason));
        message.push('\n');
    }
    message.push_str(&format!("Point {} at it, or load it with its path first.", envs.join(" or ")));
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
    stems: &'static [&'static str],
    envs: &'static [&'static str],
    half: Half,
    bind: unsafe fn(&Library, &Path, Option<(String, String)>) -> Result<A, String>,
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
        stems: &'static [&'static str],
        envs: &'static [&'static str],
        half: Half,
        bind: unsafe fn(&Library, &Path, Option<(String, String)>) -> Result<A, String>,
        names: &'static [&'static str],
    ) -> Loader<A> {
        Loader { stems, envs, half, bind, names, loaded: OnceLock::new(), loading: Mutex::new(()) }
    }

    /// The file names looked for, in order: the flavours that hold this half, then the
    /// separate library of earlier releases.
    pub(crate) fn file_names(&self) -> Vec<String> {
        self.stems.iter().map(|stem| file_name(stem)).collect()
    }

    pub(crate) fn find(&self) -> Result<PathBuf, String> {
        find(&self.file_names(), self.envs)
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
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    pub(crate) fn use_loaded(&'static self) -> Result<&'static A, String> {
        self.load_with(None, true)
    }

    #[cfg_attr(target_arch = "wasm32", allow(unreachable_code, unused_variables))]
    fn load_with(&'static self, path: Option<&Path>, loaded_only: bool) -> Result<&'static A, String> {
        #[cfg(target_arch = "wasm32")]
        return Err(no_library::refusal(&self.file_names().join(", ")));
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
            // A flavour without this half at all is refused here, by name, before anything
            // is bound.
            let flavour = flavour_of(&library);
            if let Some((name, features)) = &flavour {
                if !features.split(',').any(|f| f == self.half.feature) {
                    return Err(format!(
                        "{}: the '{name}' flavour has no {}; load {}",
                        path.display(),
                        self.half.what,
                        self.half.instead
                    ));
                }
            }
            let api = (self.bind)(&library, &path, flavour)?;
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
        format!("none of {} is loaded in this process", self.file_names().join(", "))
    }

    /// The first library of these file names the process already holds, with the file it
    /// was loaded from (its bare name where the system cannot say). Loads nothing.
    fn in_process(&self) -> Option<(Library, PathBuf)> {
        let probe = self.names.first().copied().unwrap_or_default();
        self.file_names().into_iter().find_map(|name| {
            let (library, path) = held(&name, probe)?;
            Some((library, path.unwrap_or_else(|| PathBuf::from(&name))))
        })
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

/// What stands in for `libloading` on wasm32, where nothing is loaded from a file: the
/// kernel comes from the web package ([`crate::web`]), and the reader and the native view
/// libraries are not available in the browser yet. Every load refuses, saying so.
#[cfg(target_arch = "wasm32")]
mod no_library {
    use std::fmt;
    use std::path::Path;

    /// The refusal for the library file `name`.
    pub(crate) fn refusal(name: &str) -> String {
        format!(
            "{name} cannot be loaded in the browser: the kernel comes from the web package              (cadaclysm_sdk::web::load), and the reader and the native viewers aren't available              in the browser yet"
        )
    }

    /// Why a load refused.
    #[derive(Debug)]
    pub(crate) struct NoLibrary(String);

    impl fmt::Display for NoLibrary {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(&self.0)
        }
    }

    /// A library that is never loaded.
    pub(crate) struct Library(());

    impl Library {
        pub(crate) unsafe fn new(path: impl AsRef<Path>) -> Result<Library, NoLibrary> {
            let name = path.as_ref().file_name().map_or_else(|| "the library".into(), |n| n.to_string_lossy().into_owned());
            Err(NoLibrary(refusal(&name)))
        }

        pub(crate) unsafe fn get<T: 'static>(&self, _symbol: &[u8]) -> Result<Symbol<T>, NoLibrary> {
            Err(NoLibrary(refusal("the library")))
        }
    }

    /// A symbol of a library that is never loaded: never made.
    pub(crate) struct Symbol<T: 'static>(&'static T);

    impl<T: 'static> std::ops::Deref for Symbol<T> {
        type Target = T;
        fn deref(&self) -> &T {
            self.0
        }
    }
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
