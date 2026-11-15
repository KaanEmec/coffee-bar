<#
coffee-bar installer for Windows (per user, no admin rights).
  Install or upgrade:  irm https://github.com/KaanEmec/coffee-bar/releases/latest/download/install.ps1 | iex
  Uninstall:           & ([scriptblock]::Create((irm https://github.com/KaanEmec/coffee-bar/releases/latest/download/install.ps1))) -Uninstall
Options: -Version X.Y.Z, -StartAtLogin, -NoLaunch, -Uninstall, -ZipPath <local zip> (skips the download).
#>
param(
    [string]$Version = '',
    [switch]$StartAtLogin,
    [switch]$NoLaunch,
    [switch]$Uninstall,
    [string]$ZipPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo     = 'KaanEmec/coffee-bar'
$Dir      = Join-Path $env:LOCALAPPDATA 'Programs\coffee-bar'
$Exe      = Join-Path $Dir 'coffee-bar.exe'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'coffee-bar.lnk'
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

function Say($text) { Write-Host "  $text" -ForegroundColor Yellow }

# Stops a running coffee-bar, then lets the old exe undo anything a forced stop left behind
# (lid setting, state file, RunOnce value).
function Stop-CoffeeBar {
    $running = @(Get-Process -Name 'coffee-bar' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    $old = $running[0].Path
    $running | Stop-Process -Force
    $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    if ($old -and (Test-Path $old)) { Start-Process -FilePath $old -ArgumentList '--restore' -Wait }
}

if ($Uninstall) {
    Stop-CoffeeBar
    if (Test-Path $Exe) { Start-Process -FilePath $Exe -ArgumentList '--restore' -Wait }
    Remove-ItemProperty -Path $RunKey -Name 'coffee-bar' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $Approved -Name 'coffee-bar' -ErrorAction SilentlyContinue
    Remove-Item 'HKCU:\Software\coffee-bar' -Recurse -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:LOCALAPPDATA 'coffee-bar') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Say 'coffee-bar is uninstalled.'
    return
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
$zipName = "coffee-bar-windows-$arch.zip"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("coffee-bar-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp $zipName
    if ($ZipPath) {
        Copy-Item $ZipPath $zip
    } else {
        $base = if ($Version) { "https://github.com/$Repo/releases/download/v$($Version.TrimStart('v'))" } else { "https://github.com/$Repo/releases/latest/download" }
        Say "Downloading coffee-bar $Version ($arch)..."
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$zipName" -OutFile $zip
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS").Content
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $line = ($sums -split "`n") | Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($zipName))\s*$" } | Select-Object -First 1
        $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash
        if (-not $line -or ($line.Substring(0, 64) -ne $actual)) { throw "Checksum mismatch for $zipName; not installing." }
    }

    Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
    $newExe = Join-Path $tmp 'x\coffee-bar.exe'
    if (-not (Test-Path $newExe)) { throw "$zipName does not contain coffee-bar.exe." }

    Stop-CoffeeBar
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Copy-Item $newExe $Exe -Force
    Unblock-File $Exe

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Shortcut)
    $lnk.TargetPath = $Exe
    $lnk.WorkingDirectory = $Dir
    $lnk.Description = 'Keep your laptop awake for a chosen time'
    $lnk.Save()

    # Start at login: the same value the app writes. An existing value keeps its on/off state;
    # the app itself updates the path on its next launch.
    if ($StartAtLogin) {
        if (-not (Test-Path $RunKey)) { New-Item -Path $RunKey | Out-Null }   # missing on a fresh profile
        Set-ItemProperty -Path $RunKey -Name 'coffee-bar' -Value "`"$Exe`" --autostart"
        Remove-ItemProperty -Path $Approved -Name 'coffee-bar' -ErrorAction SilentlyContinue
    } elseif (Get-ItemProperty -Path $RunKey -Name 'coffee-bar' -ErrorAction SilentlyContinue) {
        Set-ItemProperty -Path $RunKey -Name 'coffee-bar' -Value "`"$Exe`" --autostart"
    }

    $installed = (Get-Item $Exe).VersionInfo.ProductVersion
    Say "Installed coffee-bar $installed in $Dir"
    if (-not $NoLaunch) {
        Start-Process -FilePath $Exe -WorkingDirectory $Dir
        Say 'Look for the cup in the system tray (it may be under the ^ arrow for hidden icons).'
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
