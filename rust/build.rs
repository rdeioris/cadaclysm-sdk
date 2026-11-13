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
//! - From the cadaclysm source instead: when the crate is the one in the repository
//!   (a `path` dependency on a checkout, or a `git` dependency on the repository) and is
//!   built for a project outside that tree, the libraries are built from the same tree
//!   (`cargo build --release` into `<target>/cadaclysm-source`) rather than downloaded --
//!   so `cargo update` brings libraries that match the wrapper. `CADACLYSM_SDK_SOURCE=0`
//!   downloads the release instead. That directory is emptied whenever it was built from
//!   another checkout (see `claim`). A failed build from a `git` dependency fails the
//!   build, since cargo hides a git dependency's warnings; from a `path` dependency it is
//!   a warning, as a failed download is, and the libraries an earlier build copied beside
//!   the binaries are removed so that none of them is loaded in its place.
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
    // In the browser the kernel is the web package, served beside the app (src/web): there
    // is no library to download or build, for any feature.
    if env::var("CARGO_CFG_TARGET_ARCH").is_ok_and(|arch| arch == "wasm32") {
        return;
    }
    if env::var_os("CARGO_FEATURE_DOWNLOAD").is_none() || env::var_os("DOCS_RS").is_some() {
        return;
    }
    if env::var("CADACLYSM_NO_DOWNLOAD").is_ok_and(|v| !v.is_empty() && v != "0") {
        return;
    }
    // In the cadaclysm repository's source tree -- crates/cadaclysm-capi/examples/rust of a
    // checkout, or of the git checkout cargo makes for a `git = ...` dependency -- a
    // released download would be older than the crate. Two cases:
    // - built into a target directory inside that tree (the repository's own tests, the
    //   copy `cargo package` verifies under target/package/): the libraries to use are the
    //   ones built beside it, which the loader finds in target/;
    // - built for a project outside it (a `path` or `git` dependency on the source): build
    //   the libraries from that same tree, so `cargo update` brings matching ones along.
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    if let Some(repo) = manifest.ancestors().find(|dir| dir.join("crates/cadaclysm-capi/Cargo.toml").is_file()) {
        let out = PathBuf::from(env::var("OUT_DIR").unwrap());
        let source_wanted = env::var("CADACLYSM_SDK_SOURCE").map_or(true, |v| v != "0");
        println!("cargo:rerun-if-env-changed=CADACLYSM_SDK_SOURCE");
        println!("cargo:rerun-if-env-changed=CADACLYSM_LIBRARY");
        // Built inside the tree, or with the libraries already named (a developer's own
        // build, which the loader reads first): nothing to build.
        if out.starts_with(repo) || env::var_os("CADACLYSM_LIBRARY").is_some_and(|v| !v.is_empty()) {
            return;
        }
        if source_wanted {
            match from_source(repo, &out) {
                Ok(lib) => {
                    println!("cargo:rustc-env=CADACLYSM_SDK_BUNDLED={}", lib.display());
                    beside_the_binaries(&lib);
                }
                Err(reason) => {
                    let reason = reason.replace(['\n', '\r'], " ");
                    // Cargo shows a git dependency's warnings to nobody, so a build that went
                    // on would "succeed" and run the libraries an older revision left beside
                    // the binaries: fail it, saying why.
                    if is_git_checkout(repo) {
                        panic!(
                            "cadaclysm-sdk: the libraries could not be built from {}: {reason}\n\
                             (CADACLYSM_SDK_SOURCE=0 downloads the released libraries instead)",
                            repo.display()
                        );
                    }
                    println!("cargo:warning=cadaclysm-sdk: the libraries were not built from {}: {reason}", repo.display());
                    println!("cargo:warning=cadaclysm-sdk: they will be searched for at run time instead (CADACLYSM_LIBRARY, beside the executable, lib/)");
                    println!("cargo:rustc-env=CADACLYSM_SDK_DOWNLOAD_ERROR=they were not built from {}: {reason}", repo.display());
                    // Whatever an earlier build copied beside the binaries is from another
                    // state of the tree; gone, the loader's error says why instead.
                    if let Some(profile_dir) = profile_dir() {
                        remove_beside(&profile_dir, &shipped());
                    }
                }
            }
            return;
        }
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
            println!("cargo:rustc-env=CADACLYSM_SDK_DOWNLOAD_ERROR=they were not downloaded: {reason}");
        }
    }
}

/// Whether `repo` is a checkout cargo made for a `git = ...` dependency (it marks each one
/// with `.cargo-ok`), rather than a `path` dependency's working tree.
pub(crate) fn is_git_checkout(repo: &Path) -> bool {
    repo.join(".cargo-ok").is_file()
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
    if has_library(&lib) {
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
    if !status.success() || !has_library(&lib) {
        return Err(format!("unpacking {archive_name} did not give {}", lib.display()));
    }
    Ok(lib)
}

/// The library (its full flavour) and the two view libraries, built from the cadaclysm
/// source tree at `repo`, each in a cargo command of its own so their features do not
/// unify -- release profile,
/// `--locked` (a git checkout is not to be written to) -- into `<target>/cadaclysm-source`:
/// a target directory of its own, since the outer build holds the lock on its own, kept
/// beside it so it outlives `cargo update` and a newer revision builds incrementally.
fn from_source(repo: &Path, out: &Path) -> Result<PathBuf, String> {
    // Rebuild when the tree moves: a git dependency's new revision is a new checkout (and
    // so a rerun anyway); a path dependency's edits are these files.
    for watched in ["crates", "Cargo.toml", "Cargo.lock"] {
        println!("cargo:rerun-if-changed={}", repo.join(watched).display());
    }
    // OUT_DIR is <target>/[<triple>/]<profile>/build/<package>-<hash>/out; cargo marks
    // the target directory's root with CACHEDIR.TAG.
    let target_root = out
        .ancestors()
        .find(|dir| dir.join("CACHEDIR.TAG").is_file())
        .ok_or_else(|| format!("no target directory above {}", out.display()))?;
    let dir = target_root.join("cadaclysm-source");
    let target = env::var("TARGET").unwrap_or_default();
    let cross = !target.is_empty() && env::var("HOST").is_ok_and(|host| host != target);
    let lib = if cross { dir.join(&target).join("release") } else { dir.join("release") };
    let cargo = env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    claim(&dir, repo)?;

    for packages in [&["cadaclysm-lib-full"][..], &["cadaclysm-view-capi"][..], &["cadaclysm-terminal"][..]] {
        let mut command = Command::new(&cargo);
        command.current_dir(repo).args(["build", "--release", "--locked"]).arg("--target-dir").arg(&dir);
        for package in packages {
            command.args(["-p", package]);
        }
        if cross {
            command.args(["--target", &target]);
        }
        // The outer build's own variables would steer the inner one (its target directory,
        // its flags, its package): keep only what cargo needs to reach the network and to
        // share the outer build's job slots.
        for (key, _) in env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            let keep = key == "CARGO_HOME" || key == "CARGO_MAKEFLAGS" || ["CARGO_NET_", "CARGO_HTTP_", "CARGO_REGISTRIES_"].iter().any(|p| key.starts_with(p));
            if (key.starts_with("CARGO_") && !keep) || ["OUT_DIR", "TARGET", "HOST", "PROFILE", "OPT_LEVEL", "DEBUG", "NUM_JOBS", "RUSTC_WORKSPACE_WRAPPER"].contains(&key.as_str()) {
                command.env_remove(&key);
            }
        }
        let output = command.output().map_err(|e| format!("cargo: {e}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let tail: Vec<&str> = stderr.lines().rev().take(8).collect();
            return Err(format!("cargo build -p {} failed: {}", packages.join(" -p "), tail.into_iter().rev().collect::<Vec<_>>().join(" | ")));
        }
    }
    if !has_library(&lib) {
        return Err(format!("the build gave no libraries in {}", lib.display()));
    }
    Ok(lib)
}

/// The file in `<target>/cadaclysm-source` naming the checkout it was built from.
pub(crate) const CHECKOUT_STAMP: &str = "cadaclysm-checkout";

/// Make `dir` the build directory of the checkout at `repo`, emptying it first when it was
/// another checkout's (or nobody knows whose).
///
/// Cargo hashes a workspace member by its path *within* the workspace, so the `cadaclysm`
/// crate of every checkout -- each revision of a git dependency is a checkout of its own,
/// under `~/.cargo/git/checkouts` -- lands on the same file here, and whether it is fresh
/// is judged by file times alone: a checkout made before the last build of another one
/// looks older than that build's output, and that output is reused as this checkout's.
/// Emptying the directory whenever the checkout changes is the one way to rule that out
/// that does not lean on cargo's internal layout (picking out the members' fingerprints
/// would, and would only spare the registry crates a rebuild); a `path` dependency keeps
/// its one checkout, and so keeps building incrementally. Nothing in the checkout is
/// touched: a git checkout is cargo's, not to be written to.
pub(crate) fn claim(dir: &Path, repo: &Path) -> Result<(), String> {
    let checkout = repo.canonicalize().unwrap_or_else(|_| repo.to_path_buf()).display().to_string();
    let stamp = dir.join(CHECKOUT_STAMP);
    if fs::read_to_string(&stamp).is_ok_and(|recorded| recorded == checkout) {
        return Ok(());
    }
    if dir.exists() {
        fs::remove_dir_all(dir).map_err(|e| format!("could not empty {} (built from another checkout): {e}", dir.display()))?;
    }
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    fs::write(&stamp, checkout).map_err(|e| format!("{}: {e}", stamp.display()))
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

/// The platform's file name for the library whose stem is `stem`.
pub(crate) fn file_name(stem: &str) -> String {
    match env::var("CARGO_CFG_TARGET_OS").unwrap_or_default().as_str() {
        "windows" => format!("{stem}.dll"),
        "macos" => format!("lib{stem}.dylib"),
        _ => format!("lib{stem}.so"),
    }
}

/// The library the crate cannot work without: the full flavour of the single cadaclysm
/// library, which the release's `cadaclysm-<version>-<leg>` archive carries. An unpacked
/// archive lacking it is not used.
pub(crate) const LIBRARY: &str = "cadaclysm";

/// Everything copied beside the binaries: the library, and the two view libraries -- the
/// terminal that `show()` and `view()` draw with by default, and `cadaclysm_view` (wgpu).
pub(crate) const SHIPPED: [&str; 3] = ["cadaclysm", "cadaclysm_terminal", "cadaclysm_view"];

pub(crate) fn has_library(lib: &Path) -> bool {
    lib.join(file_name(LIBRARY)).is_file()
}

fn shipped() -> [String; 3] {
    SHIPPED.map(file_name)
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
/// `target/<profile>/build/<package>-<hash>/out`, three levels below. A library already
/// there is replaced unless it is byte for byte the same: two builds of a library can
/// share a size, and the program loads the one beside it before the baked-in path.
fn beside_the_binaries(lib: &Path) {
    let Some(profile_dir) = profile_dir() else { return };
    for name in shipped() {
        if !lib.join(&name).is_file() {
            let variable = if name.contains("cadaclysm_view") { "CADACLYSM_VIEW_LIBRARY" } else { "CADACLYSM_TERMINAL_LIBRARY" };
            println!("cargo:warning=cadaclysm-sdk: {name} is not in the release archive; the view will look for it elsewhere ({variable})");
            continue;
        }
        let (from, to) = (lib.join(&name), profile_dir.join(&name));
        if !same_contents(&from, &to) {
            if let Err(e) = fs::copy(&from, &to) {
                println!(
                    "cargo:warning=cadaclysm-sdk: could not copy {name} to {} ({e}); a program there loads the copy already beside it",
                    profile_dir.display()
                );
            }
        }
    }
}

/// `target/<profile>/`, where the build's binaries go: three levels above OUT_DIR.
fn profile_dir() -> Option<PathBuf> {
    PathBuf::from(env::var_os("OUT_DIR")?).ancestors().nth(3).map(Path::to_path_buf)
}

/// Whether the files `a` and `b` both exist and hold the same bytes.
pub(crate) fn same_contents(a: &Path, b: &Path) -> bool {
    let sizes = fs::metadata(a).ok().zip(fs::metadata(b).ok());
    sizes.is_some_and(|(x, y)| x.len() == y.len()) && fs::read(a).ok().zip(fs::read(b).ok()).is_some_and(|(x, y)| x == y)
}

/// Remove the libraries `names` from `profile_dir`, so that a program built there finds
/// none rather than ones from an earlier build. One that cannot go (loaded by a running
/// program) is said so.
pub(crate) fn remove_beside(profile_dir: &Path, names: &[String]) {
    for name in names {
        let path = profile_dir.join(name);
        match fs::remove_file(&path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                println!("cargo:warning=cadaclysm-sdk: could not remove the earlier build's {}: {e}", path.display());
            }
            _ => {}
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
