<#
Builds the Windows release zips on this PC (no CI): tests, x64 + arm64 release builds, checks that
the icon, manifest and version info are embedded, then zips to dist\. See BUILDING.md "Releasing".
  powershell -ExecutionPolicy Bypass -File release.ps1 [-TestInstaller]
-TestInstaller also installs and uninstalls the new x64 zip with install.ps1 (Windows PowerShell and
pwsh if present). It refuses to run if coffee-bar is already installed or running, because the
uninstall step would remove that installation and its settings.
LLVM-MinGW is found in the WinGet packages folder, or set LLVM_MINGW_BIN to its bin folder.
#>
param([switch]$TestInstaller)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Run([string]$exe) {
    # Native tools write progress to stderr; don't let Windows PowerShell treat that as an error.
    $ErrorActionPreference = 'Continue'
    & $exe @args
    if ($LASTEXITCODE) { throw "$exe $args failed ($LASTEXITCODE)" }
}

$bin = $env:LLVM_MINGW_BIN
if (-not $bin) {
    $clang = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW*\*\bin\x86_64-w64-mingw32-clang.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $clang) { throw 'LLVM-MinGW not found; set LLVM_MINGW_BIN to its bin folder.' }
    $bin = $clang.DirectoryName
}
$env:WINDRES = "$bin\llvm-windres.exe"
# build.rs runs on the host, which is the GNU toolchain: it links with the LLVM-MinGW clang driver, which has no libgcc.
# Point it at the libgcc/libgcc_eh shipped with Rust's own x86_64-pc-windows-gnu sysroot.
$env:LIBRARY_PATH = (rustc --print sysroot).Trim() + '\lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained'
foreach ($t in 'X86_64', 'AARCH64') {
    $cc = $t.ToLower()
    Set-Item "env:CARGO_TARGET_${t}_PC_WINDOWS_GNULLVM_LINKER" "$bin\$cc-w64-mingw32-clang.exe"
    Set-Item "env:CARGO_TARGET_${t}_PC_WINDOWS_GNULLVM_RUSTFLAGS" "-Cdlltool=$bin\llvm-dlltool.exe"
}

Run rustup target add x86_64-pc-windows-gnullvm aarch64-pc-windows-gnullvm
Run cargo test
Run cargo build --release --target x86_64-pc-windows-gnullvm
Run cargo build --release --target aarch64-pc-windows-gnullvm

$version = (Select-String -Path Cargo.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory dist | Out-Null
foreach ($a in @{ name = 'x64'; triple = 'x86_64-pc-windows-gnullvm' }, @{ name = 'arm64'; triple = 'aarch64-pc-windows-gnullvm' }) {
    $exe = "target\$($a.triple)\release\coffee-bar.exe"
    $res = & "$bin\llvm-readobj.exe" --coff-resources $exe | Out-String
    foreach ($kind in 'ICON', 'GROUP_ICON', 'VERSION', 'MANIFEST') {
        if ($res -notmatch "Type: $kind") { throw "$($a.name): resource $kind missing" }
    }
    if ((Get-Item $exe).VersionInfo.ProductVersion -ne $version) { throw "$($a.name): ProductVersion is not $version" }
    $stage = "dist\stage-$($a.name)"
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item $exe "$stage\coffee-bar.exe"
    Compress-Archive "$stage\coffee-bar.exe" "dist\coffee-bar-windows-$($a.name).zip"
    Remove-Item $stage -Recurse -Force
}

if ($TestInstaller) {
    $exe = "$env:LOCALAPPDATA\Programs\coffee-bar\coffee-bar.exe"
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'coffee-bar.lnk'
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ((Test-Path $exe) -or (Get-Process coffee-bar -ErrorAction SilentlyContinue) -or (Get-ItemProperty $run -Name coffee-bar -ErrorAction SilentlyContinue)) {
        throw 'coffee-bar is installed, running or set to start at login here; not testing the installer.'
    }
    $shells = @('powershell') + @(Get-Command pwsh -ErrorAction SilentlyContinue | ForEach-Object { 'pwsh' })
    foreach ($ps in $shells) {
        Run $ps -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ZipPath dist\coffee-bar-windows-x64.zip -NoLaunch -StartAtLogin
        if (-not (Test-Path $exe) -or -not (Test-Path $lnk) -or -not (Get-ItemProperty $run -Name coffee-bar -ErrorAction SilentlyContinue)) { throw "$ps install: something is missing" }
        Run $ps -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
        if ((Test-Path $exe) -or (Test-Path $lnk) -or (Get-ItemProperty $run -Name coffee-bar -ErrorAction SilentlyContinue)) { throw "$ps uninstall left something behind" }
        Write-Host "install.ps1 OK under $ps"
    }
}

Get-ChildItem dist\*.zip | ForEach-Object { '{0}  {1}  ({2} bytes)' -f (Get-FileHash -Algorithm SHA256 $_).Hash.ToLower(), $_.Name, $_.Length }
