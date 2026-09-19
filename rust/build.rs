//! The `download` feature (on by default): fetch this platform's cadaclysm libraries
//! for the crate's own version from the SDK's release, check them against the release's
//! `SHA256SUMS`, and unpack them where the crate will find them -- so `cargo run` works
//! with no `lib/` directory and no environment variable.
//!
//! - The directory is baked into the crate (`CADACLYSM_SDK_BUNDLED`), and the libraries
//!   are also copied beside the build's binaries (`target/<profile>/`), which is where
//!   they go when shipping.
//! - A failed download is a warning, not an error: the build goes on and the libraries
//!   are searched for as without the feature (see `loader::find`), and the reason is
//!   baked in (`CADACLYSM_SDK_DOWNLOAD_ERROR`) so a missing library says why.
//! - Off with `default-features = false`, or `CADACLYSM_NO_DOWNLOAD=1` in the build's
//!   environment (for a crate that depends on this one); never on docs.rs.
//!
//! `curl` and `tar` do the network and the unpacking -- both ship with Windows 10 and
//! later, macOS and every Linux distribution -- so the build pulls in no HTTP or archive
//! crate, and still needs no C toolchain.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const RELEASES: &str = "https://github.com/rdeioris/cadaclysm-sdk/releases/download";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CADACLYSM_NO_DOWNLOAD");
    println!("cargo:rerun-if-env-changed=CADACLYSM_SDK_RELEASE");
    if env::var_os("CARGO_FEATURE_DOWNLOAD").is_none() || env::var_os("DOCS_RS").is_some() {
        return;
    }
    if env::var("CADACLYSM_NO_DOWNLOAD").is_ok_and(|v| !v.is_empty() && v != "0") {
        return;
    }
    // In the cadaclysm repository itself (crates/cadaclysm-capi/examples/rust, or the
    // copy `cargo package` verifies under its target/package/) the libraries to use are
    // the ones being built beside it, which the loader finds in target/; a released
    // download would be found first and be older than the crate.
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    if manifest.ancestors().any(|dir| dir.join("crates/cadaclysm-capi/Cargo.toml").is_file()) {
        return;
    }
    match fetch() {
        Ok(lib) => {
            println!("cargo:rustc-env=CADACLYSM_SDK_BUNDLED={}", lib.display());
            beside_the_binaries(&lib);
        }
        Err(reason) => {
            let reason = reason.replace(['\n', '\r'], " ");
            println!("cargo:warning=cadaclysm-sdk: the libraries were not downloaded: {reason}");
            println!("cargo:warning=cadaclysm-sdk: they will be searched for at run time instead (CADACLYSM_LIBRARY, beside the executable, lib/)");
            println!("cargo:rustc-env=CADACLYSM_SDK_DOWNLOAD_ERROR={reason}");
        }
    }
}

/// The unpacked `lib/` directory for this target, downloading it on the first build.
fn fetch() -> Result<PathBuf, String> {
    // The release to fetch: the crate's own, which is what its entry points were bound
    // against. The override is for trying a crate against another release's libraries.
    let version = env::var("CADACLYSM_SDK_RELEASE")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| env::var("CARGO_PKG_VERSION").unwrap());
    let (leg, extension) = leg()?;
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let name = format!("cadaclysm-{version}-{leg}");
    let lib = out.join(&name).join("lib");
    if has_both(&lib) {
        return Ok(lib);
    }

    let archive_name = format!("{name}.{extension}");
    let archive = out.join(&archive_name);
    let sums = out.join(format!("SHA256SUMS-{version}"));
    download(&format!("{RELEASES}/v{version}/SHA256SUMS"), &sums)?;
    download(&format!("{RELEASES}/v{version}/{archive_name}"), &archive)?;

    let listed = fs::read_to_string(&sums).map_err(|e| format!("{}: {e}", sums.display()))?;
    let expected = listed
        .lines()
        .find_map(|line| line.split_once("  ").filter(|(_, file)| file.trim() == archive_name).map(|(hash, _)| hash.trim().to_lowercase()))
        .ok_or_else(|| format!("{archive_name} is not in the v{version} release's SHA256SUMS"))?;
    let bytes = fs::read(&archive).map_err(|e| format!("{}: {e}", archive.display()))?;
    let actual = hex(&sha256(&bytes));
    if actual != expected {
        let _ = fs::remove_file(&archive);
        return Err(format!("{archive_name} does not match SHA256SUMS ({actual}, expected {expected})"));
    }

    let status = Command::new(tool("tar"))
        .arg("-xf")
        .arg(&archive)
        .arg("-C")
        .arg(&out)
        .status()
        .map_err(|e| format!("tar: {e}"))?;
    let _ = fs::remove_file(&archive);
    if !status.success() || !has_both(&lib) {
        return Err(format!("unpacking {archive_name} did not give {}", lib.display()));
    }
    Ok(lib)
}

/// The release archive this target runs: its leg name and extension.
fn leg() -> Result<(&'static str, &'static str), String> {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    match (os.as_str(), arch.as_str(), target_env.as_str()) {
        ("windows", "x86_64", "msvc" | "gnu") => Ok(("windows-x64", "zip")),
        ("macos", "x86_64" | "aarch64", _) => Ok(("macos-universal", "tar.gz")),
        ("linux", "x86_64", "gnu") => Ok(("linux-x64", "tar.gz")),
        ("linux", "aarch64", "gnu") => Ok(("linux-arm64", "tar.gz")),
        _ => Err(format!("no prebuilt libraries for {arch}-{os}-{target_env}")),
    }
}

fn file_names() -> [String; 2] {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    ["cadaclysm_capi", "cadaclysm_blacksmith"].map(|stem| match os.as_str() {
        "windows" => format!("{stem}.dll"),
        "macos" => format!("lib{stem}.dylib"),
        _ => format!("lib{stem}.so"),
    })
}

fn has_both(lib: &Path) -> bool {
    file_names().iter().all(|name| lib.join(name).is_file())
}

/// `curl` or `tar`: on Windows the system's own, by path, since a Git or MSYS shell puts
/// GNU tar first on `PATH` and GNU tar cannot read the Windows archive, a zip.
fn tool(name: &str) -> PathBuf {
    if cfg!(windows) {
        if let Some(root) = env::var_os("SystemRoot") {
            let system = Path::new(&root).join("System32").join(format!("{name}.exe"));
            if system.is_file() {
                return system;
            }
        }
    }
    PathBuf::from(name)
}

fn download(url: &str, to: &Path) -> Result<(), String> {
    let status = Command::new(tool("curl"))
        .args(["--fail", "--silent", "--show-error", "--location", "--retry", "2", "--output"])
        .arg(to)
        .arg(url)
        .status()
        .map_err(|e| format!("curl: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        let _ = fs::remove_file(to);
        Err(format!("curl could not fetch {url}"))
    }
}

/// Copy the libraries to `target/<profile>/`, beside the binaries this build makes --
/// where a program finds them first, and what to ship with it. OUT_DIR is
/// `target/<profile>/build/<package>-<hash>/out`, three levels below. A copy that fails
/// (a library still loaded by a running program) is left to the baked-in path.
fn beside_the_binaries(lib: &Path) {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let Some(profile_dir) = out.ancestors().nth(3) else { return };
    for name in file_names() {
        let (from, to) = (lib.join(&name), profile_dir.join(&name));
        let same = fs::metadata(&to).ok().zip(fs::metadata(&from).ok()).is_some_and(|(a, b)| a.len() == b.len());
        if !same {
            if let Err(e) = fs::copy(&from, &to) {
                println!("cargo:warning=cadaclysm-sdk: could not copy {name} to {}: {e}", profile_dir.display());
            }
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// SHA-256 (FIPS 180-4), here rather than a dependency: the build checks one archive.
fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
        0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
        0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
        0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] =
        [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, value) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}
