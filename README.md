# coffee-bar

A tiny tray / menu-bar app that keeps your laptop awake for a chosen time (30 minutes to 24 hours, or a custom duration) — **even with the lid closed**. Everything it changes is undone when the time is up, when you exit, or after a crash. A heat fuse puts the machine to sleep if it gets too hot, for example in a closed bag.

- **Windows** (Rust): working; tested on Windows 11.
- **macOS** (Swift, macOS 13+): first version written, not yet built or tested.

No window, just a tray icon and its menu: `Keep awake ›` (durations, `Custom…`), `Heat fuse`, `Start at login`, `Exit`.

```
windows/   Rust app → coffee-bar.exe
macos/     Swift app (XcodeGen project) → CoffeeBar.app + CoffeeBarHelper
assets/    make-icons.ps1: regenerates every icon for both platforms
```

## Windows

### One-time setup (no Visual Studio needed)

```powershell
winget install --id Rustlang.Rustup -e
winget install --id MartinStorsjo.LLVM-MinGW.UCRT -e
rustup target add x86_64-pc-windows-gnullvm
```

`windows/.cargo/config.toml` builds for `x86_64-pc-windows-gnullvm`. Tell cargo where LLVM-MinGW lives in your **user** config `~/.cargo/config.toml`; the path depends on the machine:

```toml
[target.x86_64-pc-windows-gnullvm]
linker = "C:/Users/<you>/AppData/Local/Microsoft/WinGet/Packages/MartinStorsjo.LLVM-MinGW.UCRT_<…>/llvm-mingw-<version>-ucrt-x86_64/bin/x86_64-w64-mingw32-clang.exe"
rustflags = ["-C", "dlltool=<same bin folder>/llvm-dlltool.exe"]
```

`build.rs` embeds the app icon and manifest (`app.rc`) with `llvm-windres`, which it finds next to that linker; set `WINDRES` to override.

Don't use the plain `x86_64-pc-windows-gnu` target with LLVM's dlltool: the binaries crash at startup (broken import stubs).

### Build, test, run

```bash
cd windows
cargo test                                    # unit tests
cargo test -- --ignored --test-threads=1      # also touch the real power plan / registry, then restore it
cargo build --release                         # target/x86_64-pc-windows-gnullvm/release/coffee-bar.exe
```

`coffee-bar.exe --restore` only undoes leftover changes from a crashed run and exits.

## macOS

Needs a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd macos
xcodegen generate
open CoffeeBar.xcodeproj
```

Before the first build: set your team in the project (`DEVELOPMENT_TEAM` in `project.yml`) and the `teamID` constant in `Shared/HelperProtocol.swift`. The helper only accepts connections from an app signed by that team.

## Icons

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File assets/make-icons.ps1
```

This regenerates `windows/icons/*` (32×32 raw RGBA files embedded in the exe, plus PNG previews and `app.ico`) and `macos/CoffeeBar/Assets.xcassets`.
