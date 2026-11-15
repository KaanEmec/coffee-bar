//! Registry: start at login, the heat-fuse setting, taskbar theme.

use std::ffi::c_void;
use windows::core::PCWSTR;
use windows::Win32::System::Registry::*;

const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const APPROVED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const THEME: &str = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
const APP: &str = r"Software\coffee-bar";
const NAME: &str = "coffee-bar";

fn w(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Raw value bytes, or None when the value is missing.
fn get(sub: &str, name: &str) -> Option<Vec<u8>> {
    let (sub, name) = (w(sub), w(name));
    let mut len = 0u32;
    let (s, n) = (PCWSTR(sub.as_ptr()), PCWSTR(name.as_ptr()));
    unsafe {
        if RegGetValueW(HKEY_CURRENT_USER, s, n, RRF_RT_ANY, None, None, Some(&mut len)).is_err() {
            return None;
        }
        let mut buf = vec![0u8; len as usize];
        RegGetValueW(HKEY_CURRENT_USER, s, n, RRF_RT_ANY, None, Some(buf.as_mut_ptr() as *mut c_void), Some(&mut len))
            .is_ok()
            .then(|| {
                buf.truncate(len as usize);
                buf
            })
    }
}

fn dword(sub: &str, name: &str) -> Option<u32> {
    get(sub, name).and_then(|b| Some(u32::from_le_bytes(b.get(..4)?.try_into().ok()?)))
}

/// Set a value; `kind` is REG_SZ or REG_DWORD.
fn set(sub: &str, name: &str, kind: REG_VALUE_TYPE, data: &[u8]) -> Result<(), String> {
    let (sub, name) = (w(sub), w(name));
    let e = unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(sub.as_ptr()),
            PCWSTR(name.as_ptr()),
            kind.0,
            Some(data.as_ptr() as *const c_void),
            data.len() as u32,
        )
    };
    e.ok().map_err(|e| e.to_string())
}

/// Delete a value; a missing value is fine.
fn del(sub: &str, name: &str) -> Result<(), String> {
    let (sub, name) = (w(sub), w(name));
    let e = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, PCWSTR(sub.as_ptr()), PCWSTR(name.as_ptr())) };
    if e.is_ok() || e.0 == 2 || e.0 == 3 {
        Ok(())
    } else {
        Err(format!("registry error {}", e.0))
    }
}


/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\coffee-bar` exists and is not disabled
/// under `...\Explorer\StartupApproved\Run`.
pub fn autostart_enabled() -> bool {
    get(RUN, NAME).is_some() && get(APPROVED, NAME).and_then(|b| b.first().copied()).map_or(true, |b| b % 2 == 0)
}

/// On: write `"<current exe>" --autostart` to the Run key and clear a "disabled" StartupApproved entry.
/// Off: delete the Run value.
pub fn set_autostart(on: bool) -> Result<(), String> {
    if !on {
        return del(RUN, NAME);
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let cmd = format!("\"{}\" --autostart", exe.display());
    let bytes: Vec<u8> = w(&cmd).iter().flat_map(|c| c.to_le_bytes()).collect();
    set(RUN, NAME, REG_SZ, &bytes)?;
    del(APPROVED, NAME)
}

/// `HKCU\Software\coffee-bar\HeatFuse` (DWORD); default true when missing.
pub fn heat_fuse() -> bool {
    dword(APP, "HeatFuse").map_or(true, |v| v != 0)
}

pub fn set_heat_fuse(on: bool) {
    let _ = set(APP, "HeatFuse", REG_DWORD, &(on as u32).to_le_bytes());
}

/// `HKCU\...\Themes\Personalize\SystemUsesLightTheme` == 1 (default false when missing).
pub fn light_taskbar() -> bool {
    dword(THEME, "SystemUsesLightTheme") == Some(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore]
    fn round_trip() {
        let run_before = get(RUN, NAME);
        let app_before = get(APP, "HeatFuse");
        assert!(run_before.is_none(), "coffee-bar Run value already exists; not touching it");

        set_autostart(true).unwrap();
        let v = get(RUN, NAME).expect("Run value missing");
        let s = String::from_utf16_lossy(&v.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect::<Vec<_>>());
        assert!(s.trim_end_matches('\0').ends_with("\" --autostart"), "{s}");
        assert!(autostart_enabled());
        set_autostart(false).unwrap();
        assert!(get(RUN, NAME).is_none());
        assert!(!autostart_enabled());

        let orig = heat_fuse();
        set_heat_fuse(!orig);
        assert_eq!(heat_fuse(), !orig);
        set_heat_fuse(orig);
        assert_eq!(heat_fuse(), orig);
        if app_before.is_none() {
            let _ = del(APP, "HeatFuse");
            let k = w(APP);
            unsafe { let _ = RegDeleteKeyW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr())); }
        }
        println!("light_taskbar = {}", light_taskbar());
    }
}
