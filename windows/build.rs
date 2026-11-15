//! Compiles the exe's resources (icon, manifest, version info) with llvm-windres and links them in.
//! windres is taken from $WINDRES, else next to the configured linker (LLVM-MinGW), else PATH.

use std::{env, fs, path::PathBuf, process::Command};

fn main() {
    for f in ["app.manifest", "icons/app.ico"] {
        println!("cargo:rerun-if-changed={f}");
    }
    println!("cargo:rerun-if-env-changed=WINDRES");

    let windres = env::var_os("WINDRES").map(PathBuf::from).unwrap_or_else(|| {
        env::var_os("RUSTC_LINKER")
            .and_then(|l| Some(PathBuf::from(l).parent()?.join("llvm-windres.exe")))
            .filter(|p| p.exists())
            .unwrap_or_else(|| "llvm-windres".into())
    });

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let rc = out_dir.join("app.rc");
    fs::write(&rc, resources()).unwrap();
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap(); // x86_64 or aarch64
    let out = out_dir.join("app.res.o");
    let ok = Command::new(&windres)
        .args(["--target", &format!("{arch}-w64-mingw32"), "-O", "coff", "-i"])
        .arg(&rc)
        .arg("-o")
        .arg(&out)
        .status()
        .is_ok_and(|s| s.success());
    assert!(ok, "couldn't compile resources with {windres:?}; set WINDRES to llvm-windres.exe");
    println!("cargo:rustc-link-arg-bins={}", out.display());
}

/// Icon (Explorer, taskbar, Alt+Tab), the manifest (DPI awareness, common controls) and a
/// version block so Task Manager and Startup apps show "coffee-bar" with its version.
fn resources() -> String {
    let dir = env::var("CARGO_MANIFEST_DIR").unwrap().replace('\\', "/");
    let v = env::var("CARGO_PKG_VERSION").unwrap();
    let n = |k: &str| env::var(k).unwrap();
    let num = format!("{},{},{},0", n("CARGO_PKG_VERSION_MAJOR"), n("CARGO_PKG_VERSION_MINOR"), n("CARGO_PKG_VERSION_PATCH"));
    format!(
        r#"1 ICON "{dir}/icons/app.ico"
1 24 "{dir}/app.manifest"
1 VERSIONINFO
FILEVERSION {num}
PRODUCTVERSION {num}
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "FileDescription", "coffee-bar"
      VALUE "FileVersion", "{v}"
      VALUE "ProductName", "coffee-bar"
      VALUE "ProductVersion", "{v}"
      VALUE "OriginalFilename", "coffee-bar.exe"
      VALUE "LegalCopyright", "MIT License"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#
    )
}
