# Building coffee-bar

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

`build.rs` embeds the app icon, manifest and version info with `llvm-windres`, which it finds next to that linker; set `WINDRES` to override.

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
xcodebuild -scheme CoffeeBar -derivedDataPath build/DD test
xcodebuild -scheme CoffeeBar -configuration Release -derivedDataPath build/DD build
ditto build/DD/Build/Products/Release/CoffeeBar.app /Applications/CoffeeBar.app
```

The team is set in two places that must match: `DEVELOPMENT_TEAM` in `project.yml` and `teamID` in `Shared/HelperProtocol.swift`. The helper only accepts connections from an app signed by that team. Run the app from `/Applications` (SMAppService expects a stable path); on first launch, allow CoffeeBar in System Settings → General → Login Items & Extensions to enable closed-lid mode.

## Icons

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File assets/make-icons.ps1
```

This regenerates `windows/icons/*` (32×32 raw RGBA files embedded in the exe, plus PNG previews and `app.ico`) and `macos/CoffeeBar/Assets.xcassets`.

## Releasing

1. Bump the version in `windows/Cargo.toml` and `MARKETING_VERSION` in `macos/project.yml`, commit and push.
2. On the Mac: `macos/release.sh` builds the universal, Developer ID-signed `build/CoffeeBar-macos.zip` (set `NOTARY_PROFILE` to also notarize).
3. `gh release create vX.Y.Z macos/build/CoffeeBar-macos.zip --title vX.Y.Z --generate-notes`.
4. Publishing the release starts `.github/workflows/release.yml`: it builds and tests the Windows exes, checks that the icon and version are embedded, tests `install.ps1`, then attaches `coffee-bar-windows-x64.zip`, `coffee-bar-windows-arm64.zip`, `install.ps1`, `install.sh` and a `SHA256SUMS` covering every zip.

Asset names carry no version, so `releases/latest/download/<file>` always points at the newest release; the installers rely on that.
