//! System changes that keep the machine awake (see files/ARCHITECTURE.md#keeping-awake).
//!
//! Lid-close action "Do nothing" on AC and DC for the active power scheme, plus
//! `SetThreadExecutionState`. The original values are saved to a state file first, and a RunOnce
//! value restores them at next login if the app dies without calling `stop`.
//!
//! `SetThreadExecutionState` is per thread: call `start` and `stop` from the same (UI) thread.

use std::path::PathBuf;
use std::{fs, io::Write};

use windows::core::{w, GUID, PCWSTR};
use windows::Win32::Foundation::{LocalFree, ERROR_ACCESS_DENIED, ERROR_FILE_NOT_FOUND, HLOCAL, WIN32_ERROR};
use windows::Win32::System::Power::*;
use windows::Win32::System::Registry::{RegDeleteKeyValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ};
use windows::Win32::System::SystemServices::{GUID_LIDCLOSE_ACTION, GUID_SYSTEM_BUTTON_SUBGROUP};

const RUN_ONCE: PCWSTR = w!(r"Software\Microsoft\Windows\CurrentVersion\RunOnce");
const RUN_ONCE_VALUE: PCWSTR = w!("coffee-bar-restore");

/// Apply everything (state file + RunOnce safety value first, then lid action "Do nothing" on AC and DC,
/// then SetThreadExecutionState). On failure, roll back whatever was done and return a short reason.
pub fn start() -> Result<(), String> {
    // Leftovers from an earlier run hold the real originals: restore them before saving new ones.
    recover_if_needed();

    let scheme = active_scheme().map_err(|e| reason("Can't read the power plan", e))?;
    match read_lid(&scheme) {
        // Setting absent from this plan (some desktops): nothing to change, just block idle sleep.
        Err(ERROR_FILE_NOT_FOUND) => {}
        Err(e) => return Err(reason("Can't read the lid setting", e)),
        Ok((ac, dc)) => {
            write_state(&scheme, ac, dc).map_err(|e| format!("Can't save the current settings ({e})"))?;
            if let Err(e) = apply(&scheme) {
                stop(); // state file exists, so this restores whatever was changed
                return Err(e);
            }
        }
    }
    // System only, deliberately not ES_DISPLAY_REQUIRED: the screen may still turn off on its normal timeout.
    unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
    Ok(())
}

/// Restore everything `start` changed. Idempotent; a no-op when nothing is in effect.
pub fn stop() {
    unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
    let Ok(text) = fs::read_to_string(state_path()) else { return };
    if let Some((scheme, ac, dc)) = parse_state(&text) {
        match write_lid(&scheme, ac, dc) {
            // Plan deleted meanwhile: nothing left to restore.
            Ok(()) | Err(ERROR_FILE_NOT_FOUND) => {}
            // Keep the state file and RunOnce value so the next launch or login retries.
            Err(_) => return,
        }
        if active_scheme() == Ok(scheme) {
            let _ = unsafe { PowerSetActiveScheme(None, Some(&scheme)) };
        }
    }
    let _ = fs::remove_file(state_path());
    let _ = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_ONCE, RUN_ONCE_VALUE) };
}

/// At launch and for `--restore`: if a previous run left changes behind (state file exists), restore them.
pub fn recover_if_needed() {
    stop()
}

/// Put the machine to sleep now.
pub fn sleep_now() {
    unsafe { SetSuspendState(false, false, false) };
}

/// Steps 4-5 of `start`: RunOnce safety value, then lid action 0 applied to the scheme.
fn apply(scheme: &GUID) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| format!("Can't find the app's path ({e})"))?;
    let cmd: Vec<u16> = format!("\"{}\" --restore", exe.display()).encode_utf16().chain([0]).collect();
    let e = unsafe {
        RegSetKeyValueW(HKEY_CURRENT_USER, RUN_ONCE, RUN_ONCE_VALUE, REG_SZ.0, Some(cmd.as_ptr().cast()), cmd.len() as u32 * 2)
    };
    check(e).map_err(|e| reason("Can't add the restore safety net", e))?;
    write_lid(scheme, 0, 0).map_err(|e| reason("Can't change the lid setting", e))?;
    check(unsafe { PowerSetActiveScheme(None, Some(scheme)) }).map_err(|e| reason("Can't apply the lid setting", e))
}

fn active_scheme() -> Result<GUID, WIN32_ERROR> {
    let mut p: *mut GUID = std::ptr::null_mut();
    check(unsafe { PowerGetActiveScheme(None, &mut p) })?;
    let guid = unsafe { *p };
    unsafe { LocalFree(Some(HLOCAL(p.cast()))) };
    Ok(guid)
}

fn read_lid(scheme: &GUID) -> Result<(u32, u32), WIN32_ERROR> {
    let (sub, set) = (Some(&GUID_SYSTEM_BUTTON_SUBGROUP as *const _), Some(&GUID_LIDCLOSE_ACTION as *const _));
    let (mut ac, mut dc) = (0, 0);
    check(unsafe { PowerReadACValueIndex(None, Some(scheme), sub, set, &mut ac) })?;
    check(WIN32_ERROR(unsafe { PowerReadDCValueIndex(None, Some(scheme), sub, set, &mut dc) }))?;
    Ok((ac, dc))
}

fn write_lid(scheme: &GUID, ac: u32, dc: u32) -> Result<(), WIN32_ERROR> {
    let (sub, set) = (Some(&GUID_SYSTEM_BUTTON_SUBGROUP as *const _), Some(&GUID_LIDCLOSE_ACTION as *const _));
    check(unsafe { PowerWriteACValueIndex(None, scheme, sub, set, ac) })?;
    check(WIN32_ERROR(unsafe { PowerWriteDCValueIndex(None, scheme, sub, set, dc) }))
}

fn check(e: WIN32_ERROR) -> Result<(), WIN32_ERROR> {
    if e.is_ok() { Ok(()) } else { Err(e) }
}

fn reason(what: &str, e: WIN32_ERROR) -> String {
    if e == ERROR_ACCESS_DENIED { format!("{what} (access denied)") } else { format!("{what} (error {})", e.0) }
}

fn state_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("coffee-bar").join("state")
}

/// Three lines: scheme GUID, AC value, DC value. Written to a temp file, then renamed into place.
fn write_state(scheme: &GUID, ac: u32, dc: u32) -> std::io::Result<()> {
    let path = state_path();
    fs::create_dir_all(path.parent().unwrap())?;
    let tmp = path.with_extension("tmp");
    let mut f = fs::File::create(&tmp)?;
    write!(f, "{scheme:?}\n{ac}\n{dc}\n")?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, &path)
}

fn parse_state(text: &str) -> Option<(GUID, u32, u32)> {
    let mut lines = text.lines().map(str::trim);
    let scheme = GUID::try_from(lines.next()?).ok()?;
    Some((scheme, lines.next()?.parse().ok()?, lines.next()?.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::System::Registry::{RegGetValueW, RRF_RT_REG_SZ};

    fn run_once_exists() -> bool {
        unsafe { RegGetValueW(HKEY_CURRENT_USER, RUN_ONCE, RUN_ONCE_VALUE, RRF_RT_REG_SZ, None, None, None) }.is_ok()
    }

    /// Restores the machine even if an assertion fails mid-test.
    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            stop();
        }
    }

    #[test]
    fn awake_state_file_round_trip() {
        let g = GUID::from_u128(0x381b4222_f694_41f0_9685_ff5bb260df2e);
        assert_eq!(parse_state(&format!("{g:?}\n1\n2\n")), Some((g, 1, 2)));
        assert_eq!(parse_state("garbage"), None);
    }

    #[test]
    #[ignore = "changes the real power plan; run with --ignored --test-threads=1"]
    fn awake_real_round_trip_and_crash_recovery() {
        let _guard = Guard;
        let scheme = active_scheme().expect("active scheme");
        let original = read_lid(&scheme);
        println!("scheme {scheme:?}, lid (AC, DC) = {original:?}");
        let Ok(original) = original else {
            assert_eq!(original, Err(ERROR_FILE_NOT_FOUND));
            assert_eq!(start(), Ok(()));
            assert!(!state_path().exists() && !run_once_exists());
            stop();
            return;
        };

        // Normal start / stop.
        assert_eq!(start(), Ok(()));
        assert_eq!(read_lid(&scheme), Ok((0, 0)));
        assert!(run_once_exists() && state_path().exists());
        stop();
        assert_eq!(read_lid(&scheme), Ok(original));
        assert!(!run_once_exists() && !state_path().exists());
        stop(); // idempotent
        assert_eq!(read_lid(&scheme), Ok(original));

        // Crash: start, never stop, then recover as the next launch would. A second start in
        // between must not save the 0s as "originals".
        assert_eq!(start(), Ok(()));
        assert_eq!(start(), Ok(()));
        assert_eq!(read_lid(&scheme), Ok((0, 0)));
        recover_if_needed();
        assert_eq!(read_lid(&scheme), Ok(original));
        assert!(!run_once_exists() && !state_path().exists());
    }
}
