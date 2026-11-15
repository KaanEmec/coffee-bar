//! Compiles app.rc (icon + manifest) with llvm-windres and links it into the exe.
//! windres is taken from $WINDRES, else next to the configured linker (LLVM-MinGW), else PATH.

use std::{env, path::PathBuf, process::Command};

fn main() {
    for f in ["app.rc", "app.manifest", "icons/app.ico"] {
        println!("cargo:rerun-if-changed={f}");
    }
    println!("cargo:rerun-if-env-changed=WINDRES");

    let windres = env::var_os("WINDRES").map(PathBuf::from).unwrap_or_else(|| {
        env::var_os("RUSTC_LINKER")
            .and_then(|l| Some(PathBuf::from(l).parent()?.join("llvm-windres.exe")))
            .filter(|p| p.exists())
            .unwrap_or_else(|| "llvm-windres".into())
    });
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("app.res.o");
    let ok = Command::new(&windres).args(["app.rc", "-O", "coff", "-o"]).arg(&out).status().is_ok_and(|s| s.success());
    assert!(ok, "couldn't compile app.rc with {windres:?}; set WINDRES to llvm-windres.exe");
    println!("cargo:rustc-link-arg-bins={}", out.display());
}
