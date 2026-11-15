//! The "Custom…" input prompt: a small centered Win32 window with a label, an edit box,
//! OK / Cancel and an error line. Runs its own message loop until the user is done.

use std::cell::Cell;
use std::ffi::c_void;
use std::mem::size_of;
use std::time::Duration;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontIndirectW, DeleteObject, GetMonitorInfoW, GetSysColorBrush, MonitorFromPoint, SetBkMode,
    SetTextColor, COLOR_BTNFACE, HBRUSH, HDC, HFONT, HGDIOBJ, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{
    AdjustWindowRectExForDpi, GetDpiForSystem, GetDpiForWindow, SystemParametersInfoForDpi,
};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::*;

const ID_EDIT: i32 = 101;
const ID_ERROR: i32 = 102;
const ID_OK: i32 = IDOK.0;
const ID_CANCEL: i32 = IDCANCEL.0;

struct State {
    edit: Cell<HWND>,
    error: Cell<HWND>,
    done: Cell<bool>,
    result: Cell<Option<Duration>>,
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_NCCREATE {
        let cs = &*(lp.0 as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize);
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    let Some(state) = (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const State).as_ref() else {
        return DefWindowProcW(hwnd, msg, wp, lp);
    };
    match msg {
        WM_COMMAND => {
            match (wp.0 & 0xffff) as i32 {
                ID_OK => {
                    let mut buf = [0u16; 128];
                    let n = GetWindowTextW(state.edit.get(), &mut buf).max(0) as usize;
                    let text = String::from_utf16_lossy(&buf[..n]);
                    match crate::duration::parse(&text) {
                        Some(d) => {
                            state.result.set(Some(d));
                            state.done.set(true);
                        }
                        None => {
                            let _ = SetWindowTextW(
                                state.error.get(),
                                w!("Enter a time between 1 minute and 7 days."),
                            );
                            let edit = state.edit.get();
                            let _ = SetFocus(Some(edit));
                            SendMessageW(edit, 0x00B1 /* EM_SETSEL */, Some(WPARAM(0)), Some(LPARAM(-1)));
                        }
                    }
                }
                ID_CANCEL => state.done.set(true),
                _ => {}
            }
            LRESULT(0)
        }
        WM_CTLCOLORSTATIC => {
            let hdc = HDC(wp.0 as *mut c_void);
            let is_error = HWND(lp.0 as *mut c_void) == state.error.get();
            // COLORREF is 0x00BBGGRR: dark red for the error line.
            SetTextColor(hdc, COLORREF(if is_error { 0x0000_00C0 } else { 0 }));
            SetBkMode(hdc, TRANSPARENT);
            LRESULT(GetSysColorBrush(COLOR_BTNFACE).0 as isize)
        }
        WM_CLOSE => {
            state.done.set(true);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Modal prompt: label, edit box, OK/Cancel. Enter = OK, Esc = Cancel. Parses with `crate::duration::parse`;
/// on invalid input it stays open and shows an error line. Returns None on Cancel.
pub fn ask_custom() -> Option<Duration> {
    unsafe {
        let hinst: HINSTANCE = GetModuleHandleW(None).ok()?.into();
        let class = w!("CoffeeBarPrompt");
        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).ok()?,
            hbrBackground: HBRUSH((COLOR_BTNFACE.0 + 1) as usize as *mut c_void),
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassExW(&wc); // fails harmlessly if already registered

        let state = State {
            edit: Cell::new(HWND::default()),
            error: Cell::new(HWND::default()),
            done: Cell::new(false),
            result: Cell::new(None),
        };
        let style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
        let ex = WS_EX_DLGMODALFRAME | WS_EX_TOPMOST;
        let hwnd = CreateWindowExW(
            ex,
            class,
            w!("coffee-bar"),
            style,
            0,
            0,
            100,
            100,
            None,
            None,
            Some(hinst),
            Some(&state as *const State as *const c_void),
        )
        .ok()?;

        let dpi = match GetDpiForWindow(hwnd) {
            0 => GetDpiForSystem(),
            d => d,
        };
        let s = |v: i32| (v as i64 * dpi as i64 / 96) as i32;

        // System message font at this DPI.
        let mut ncm = NONCLIENTMETRICSW { cbSize: size_of::<NONCLIENTMETRICSW>() as u32, ..Default::default() };
        let font = if SystemParametersInfoForDpi(
            SPI_GETNONCLIENTMETRICS.0,
            ncm.cbSize,
            Some(&mut ncm as *mut _ as *mut c_void),
            0,
            dpi,
        )
        .is_ok()
        {
            CreateFontIndirectW(&ncm.lfMessageFont)
        } else {
            HFONT::default()
        };

        let child = |cls: PCWSTR, text: PCWSTR, st: WINDOW_STYLE, x: i32, y: i32, wd: i32, h: i32, id: i32| {
            let c = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                cls,
                text,
                WS_CHILD | WS_VISIBLE | st,
                s(x),
                s(y),
                s(wd),
                s(h),
                Some(hwnd),
                Some(HMENU(id as isize as *mut c_void)),
                Some(hinst),
                None,
            )
            .unwrap_or_default();
            SendMessageW(c, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            c
        };
        let left = WINDOW_STYLE(0) /* SS_LEFT */;
        child(w!("STATIC"), w!("Keep awake for (e.g. 45, 90m, 2h, 1h30m, 1:30):"), left, 16, 16, 368, 20, -1);
        let edit_style = WS_TABSTOP | WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32);
        let edit = child(w!("EDIT"), w!(""), edit_style, 16, 40, 368, 24, ID_EDIT);
        let error = child(w!("STATIC"), w!(""), left, 16, 72, 368, 20, ID_ERROR);
        let ok_style = WS_TABSTOP | WINDOW_STYLE(BS_DEFPUSHBUTTON as u32);
        child(w!("BUTTON"), w!("OK"), ok_style, 216, 104, 80, 26, ID_OK);
        let cancel_style = WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32);
        child(w!("BUTTON"), w!("Cancel"), cancel_style, 304, 104, 80, 26, ID_CANCEL);
        state.edit.set(edit);
        state.error.set(error);
        SendMessageW(hwnd, DM_SETDEFID, Some(WPARAM(ID_OK as usize)), Some(LPARAM(0)));

        // Size to a 400x146 (96 dpi) client area and center on the monitor under the cursor.
        let mut r = RECT { left: 0, top: 0, right: s(400), bottom: s(146) };
        let _ = AdjustWindowRectExForDpi(&mut r, style, false, ex, dpi);
        let (ww, wh) = (r.right - r.left, r.bottom - r.top);
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let mut mi = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        let (x, y) = if GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &mut mi).as_bool() {
            let a = mi.rcWork;
            (a.left + (a.right - a.left - ww) / 2, a.top + (a.bottom - a.top - wh) / 2)
        } else {
            (100, 100)
        };
        let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), x, y, ww, wh, SWP_SHOWWINDOW);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus(Some(edit));

        let mut msg = MSG::default();
        while !state.done.get() {
            match GetMessageW(&mut msg, None, 0, 0).0 {
                0 => {
                    // A WM_QUIT from elsewhere: hand it back to the outer loop and leave.
                    PostQuitMessage(msg.wParam.0 as i32);
                    break;
                }
                -1 => break,
                _ => {
                    if !IsDialogMessageW(hwnd, &msg).as_bool() {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                }
            }
        }

        let _ = DestroyWindow(hwnd);
        if !font.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(font.0));
        }
        state.result.get()
    }
}
