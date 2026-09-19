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
    format!(
        "{} has no {name}: the library is older than this copy of cadaclysm-sdk, which \
         binds {count} entry points. Use the library from the same release as the crate.",
        path.display()
    )
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
/// executable; then a `lib/` directory in any ancestor of the executable or of the
/// working directory (the SDK's layout); then a `target/release` or `target/debug`
/// in any of those ancestors (the repository's layout). No other variable is read
/// and the system's own search is not consulted, so a stray copy elsewhere on `PATH`
/// is never picked up by accident.
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
    ) -> Loader<A> {
        Loader { stem, env, bind, loaded: OnceLock::new(), loading: Mutex::new(()) }
    }

    pub(crate) fn file_name(&self) -> String {
        file_name(self.stem)
    }

    pub(crate) fn find(&self) -> Result<PathBuf, String> {
        find(&self.file_name(), self.env)
    }

    /// Load the library at `path` (or where [`Loader::find`] finds it) and bind every
    /// entry point, once. A second call naming the library already loaded is a no-op;
    /// naming another one is an error, since two copies cannot share a handle or a
    /// license.
    pub(crate) fn load(&'static self, path: Option<&Path>) -> Result<&'static A, String> {
        if let Some(loaded) = self.loaded.get() {
            return check_same(loaded, path);
        }
        let _guard = self.loading.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(loaded) = self.loaded.get() {
            return check_same(loaded, path);
        }
        let path = match path {
            Some(path) => path.to_path_buf(),
            None => self.find()?,
        };
        // SAFETY: loading runs the library's initialisers, and every symbol is then
        // read as the signature the table declares. Both are the contract of loading
        // a cadaclysm library at all; nothing on this side can check `path` is one.
        let loaded = unsafe {
            let library = Library::new(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let api = (self.bind)(&library, &path)?;
            Loaded { api, path, _library: library }
        };
        Ok(&self.loaded.get_or_init(|| loaded).api)
    }

    /// The path the library was loaded from, or `None` before anything loaded it.
    pub(crate) fn loaded_path(&'static self) -> Option<&'static Path> {
        self.loaded.get().map(|loaded| loaded.path.as_path())
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
