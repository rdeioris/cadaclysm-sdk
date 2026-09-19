//! cadaclysm for Godot 4: a GDExtension over the prebuilt cadaclysm libraries.
//!
//! Every class here is a thin layer over the `cadaclysm-sdk` crate, which opens the
//! reader (`cadaclysm_capi`) and the kernel (`cadaclysm_blacksmith`) at run time. The
//! object model is the Python wrapper's -- `CadaclysmScene`, `CadaclysmNode`, `CadaclysmPlacement`,
//! `CadaclysmSolid`, `CadaclysmProfile`... -- with Godot's own types where Godot has one: a
//! `Transform3D` for a transform, an `AABB` for bounds, a `Color` for a colour and an
//! `ArrayMesh` for triangles.
//!
//! **Errors.** GDScript has no exceptions, so a call that fails returns `null` (or an
//! empty value, or `false`), reports the reason with `push_error`, and leaves it in
//! `Cadaclysm.last_error()` -- the way `FileAccess.open` and `get_open_error` work.
//! A call that succeeds clears it.
use std::cell::RefCell;
use std::fmt::Display;
use std::path::PathBuf;

use godot::prelude::*;

mod blacksmith;
mod drawing;
mod importer;
mod meshes;
mod reader;

struct CadaclysmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for CadaclysmExtension {
    fn on_stage_init(stage: InitStage) {
        if stage == InitStage::Scene {
            find_libraries();
        }
    }

    fn on_stage_deinit(stage: InitStage) {
        if stage == InitStage::Scene {
            meshes::release_cache();
        }
    }
}

// ---- errors ------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Record `message` as the last error, report it, and return `None`.
pub(crate) fn fail<T>(message: impl Display) -> Option<T> {
    let message = message.to_string();
    godot_error!("cadaclysm: {message}");
    LAST_ERROR.with(|last| *last.borrow_mut() = message);
    None
}

/// A result as an option: `Err` is reported and recorded, `Ok` clears the last error.
pub(crate) fn ok<T, E: Display>(result: Result<T, E>) -> Option<T> {
    match result {
        Ok(value) => {
            clear_error();
            Some(value)
        }
        Err(error) => fail(error),
    }
}

pub(crate) fn clear_error() {
    LAST_ERROR.with(|last| last.borrow_mut().clear());
}

pub(crate) fn last_error() -> String {
    LAST_ERROR.with(|last| last.borrow().clone())
}

// ---- finding the libraries ---------------------------------------------------------

/// Load the reader and the kernel from beside this extension, where the addon keeps
/// them (`addons/cadaclysm/bin/<platform>/`) and where an exported game has them (next to the
/// executable, copied there by the `.gdextension` file's `[dependencies]`).
///
/// Only where the file is there and the environment does not name another: otherwise
/// the SDK's own search runs on first use (`CADACLYSM_LIBRARY`, beside the executable,
/// `lib/` or `target/` in an ancestor), and its error names everywhere it looked.
fn find_libraries() {
    let Some(dir) = own_dir() else { return };
    let pairs = [
        ("CADACLYSM_LIBRARY", "cadaclysm_capi"),
        ("CADACLYSM_BLACKSMITH_LIBRARY", "cadaclysm_blacksmith"),
    ];
    for (env, stem) in pairs {
        if std::env::var_os(env).is_some_and(|v| !v.is_empty()) {
            continue;
        }
        let path = dir.join(library_file(stem));
        if !path.is_file() {
            continue;
        }
        let loaded = if stem == "cadaclysm_capi" {
            cadaclysm_sdk::load(&path)
        } else {
            cadaclysm_sdk::blacksmith::load(&path)
        };
        if let Err(error) = loaded {
            godot_error!("cadaclysm: {error}");
        }
    }
}

pub(crate) fn library_file(stem: &str) -> String {
    if cfg!(windows) {
        format!("{stem}.dll")
    } else if cfg!(target_os = "macos") {
        format!("lib{stem}.dylib")
    } else {
        format!("lib{stem}.so")
    }
}

/// The directory this extension's own library was loaded from.
#[cfg(windows)]
fn own_dir() -> Option<PathBuf> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStringExt;
    extern "system" {
        fn GetModuleHandleExW(flags: u32, address: *const u16, module: *mut *mut c_void) -> i32;
        fn GetModuleFileNameW(module: *mut c_void, name: *mut u16, size: u32) -> u32;
    }
    const FROM_ADDRESS: u32 = 0x4;
    const UNCHANGED_REFCOUNT: u32 = 0x2;
    let mut module = std::ptr::null_mut();
    let mut name = vec![0u16; 32768];
    // SAFETY: the address is a function of this library, the buffer's length is passed.
    let length = unsafe {
        if GetModuleHandleExW(FROM_ADDRESS | UNCHANGED_REFCOUNT, own_dir as *const u16, &mut module) == 0 {
            return None;
        }
        GetModuleFileNameW(module, name.as_mut_ptr(), name.len() as u32)
    } as usize;
    if length == 0 || length >= name.len() {
        return None;
    }
    let path = PathBuf::from(std::ffi::OsString::from_wide(&name[..length]));
    path.parent().map(PathBuf::from)
}

/// The directory this extension's own library was loaded from.
#[cfg(unix)]
fn own_dir() -> Option<PathBuf> {
    use std::ffi::{c_char, c_void, CStr};
    use std::os::unix::ffi::OsStrExt;
    #[repr(C)]
    struct DlInfo {
        fname: *const c_char,
        fbase: *mut c_void,
        sname: *const c_char,
        saddr: *mut c_void,
    }
    extern "C" {
        fn dladdr(address: *const c_void, info: *mut DlInfo) -> i32;
    }
    let mut info = DlInfo {
        fname: std::ptr::null(),
        fbase: std::ptr::null_mut(),
        sname: std::ptr::null(),
        saddr: std::ptr::null_mut(),
    };
    // SAFETY: the address is a function of this library; dladdr only fills `info`.
    if unsafe { dladdr(own_dir as *const c_void, &mut info) } == 0 || info.fname.is_null() {
        return None;
    }
    let name = unsafe { CStr::from_ptr(info.fname) };
    let path = PathBuf::from(std::ffi::OsStr::from_bytes(name.to_bytes()));
    path.parent().map(PathBuf::from)
}

pub(crate) fn gs(s: impl AsRef<str>) -> GString {
    GString::from(s.as_ref())
}

/// A dictionary from `(key, value)` pairs, in order.
pub(crate) fn dict(pairs: &[(&str, Variant)]) -> VarDictionary {
    let mut d = VarDictionary::new();
    for (key, value) in pairs {
        d.set(*key, value);
    }
    d
}

// ---- paths -------------------------------------------------------------------------

/// A path as the libraries want it: `res://` and `user://` made into the file system
/// path they stand for. (In an exported game `res://` lives inside the pack, so there
/// is no such file; `CadaclysmScene.open` reads it through `FileAccess` then.)
pub(crate) fn os_path(path: &GString) -> String {
    let text = path.to_string();
    if text.starts_with("res://") || text.starts_with("user://") {
        godot::classes::ProjectSettings::singleton().globalize_path(path).to_string()
    } else {
        text
    }
}
