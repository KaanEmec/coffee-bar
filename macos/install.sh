#!/bin/bash
# coffee-bar installer for macOS.
#   Install or upgrade:  curl -fsSL https://github.com/KaanEmec/coffee-bar/releases/latest/download/install.sh | bash
#   Uninstall:           curl -fsSL https://github.com/KaanEmec/coffee-bar/releases/latest/download/install.sh | bash -s -- --uninstall
# Options: --version X.Y.Z, --no-launch, --uninstall. COFFEEBAR_ZIP=/path/to.zip installs a local build.
set -euo pipefail

repo="KaanEmec/coffee-bar"
bundle_id="com.coffeebar.app"
version="" launch=1 uninstall=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="${2#v}"; shift ;;
        --no-launch) launch=0 ;;
        --uninstall) uninstall=1 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\033[1m☕ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "This installer is for macOS. On Windows, use install.ps1."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "coffee-bar needs macOS 13 or newer."

# Where it is (or goes): /Applications if writable, else ~/Applications.
existing=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | grep -E '^(/Applications|'"$HOME"'/Applications)/CoffeeBar\.app$' | head -1 || true)
if [ -n "$existing" ]; then
    dest=$(dirname "$existing")
elif [ -w /Applications ]; then
    dest=/Applications
else
    dest="$HOME/Applications"
fi
app="$dest/CoffeeBar.app"

quit_app() {
    pgrep -xq CoffeeBar || return 0
    # A normal quit undoes everything the app changed (the helper also restores sleep on its own).
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq CoffeeBar || return 0; sleep 0.5; done
    pkill -x CoffeeBar || true
}

if [ "$uninstall" = 1 ]; then
    quit_app
    [ -d "$app" ] && "$app/Contents/MacOS/CoffeeBar" --uninstall || true   # removes helper + login item
    rm -rf "$app"
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    say "coffee-bar is uninstalled."
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -n "${COFFEEBAR_ZIP:-}" ]; then
    cp "$COFFEEBAR_ZIP" "$tmp/CoffeeBar-macos.zip"
else
    base="https://github.com/$repo/releases/latest/download"
    [ -n "$version" ] && base="https://github.com/$repo/releases/download/v$version"
    say "Downloading coffee-bar${version:+ $version}…"
    curl -fsSL "$base/CoffeeBar-macos.zip" -o "$tmp/CoffeeBar-macos.zip" || fail "Download failed: $base/CoffeeBar-macos.zip"
    curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || fail "Download failed: $base/SHA256SUMS"
    expected=$(awk '$2 == "CoffeeBar-macos.zip" || $2 == "*CoffeeBar-macos.zip" {print $1}' "$tmp/SHA256SUMS")
    actual=$(shasum -a 256 "$tmp/CoffeeBar-macos.zip" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "Checksum mismatch; not installing."
fi

ditto -x -k "$tmp/CoffeeBar-macos.zip" "$tmp/x"
codesign --verify --deep --strict "$tmp/x/CoffeeBar.app" || fail "The downloaded app's signature is invalid; not installing."

quit_app
mkdir -p "$dest"
rm -rf "$app"
mv "$tmp/x/CoffeeBar.app" "$app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

installed=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "Installed coffee-bar $installed in $dest."
if [ "$launch" = 1 ]; then
    open "$app"
    echo "   Look for the cup in the menu bar (it can hide behind the notch if the bar is full)."
fi
# The app starts its closed-lid helper right after launch. If launchd isn't running it, the helper
# needs approval: on a fresh install, and again after an update (macOS asks again when the app
# changes). Then open the page where it is approved.
if [ "$launch" = 1 ]; then
    for _ in 1 2 3 4 5 6; do
        sleep 1
        launchctl print system/com.coffeebar.helper 2>/dev/null | grep -q "state = running" && exit 0
    done
    open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    printf '\n\033[1m👉 Turn on CoffeeBar under "Allow in the Background"\033[0m (System Settings → General →\n   Login Items & Extensions). This enables closed-lid mode; macOS asks again after each update.\n'
fi
