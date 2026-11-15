#![windows_subsystem = "windows"]

mod awake;
mod dialog;
mod duration;
mod menu;
mod reg;
mod session;
mod thermal;

use menu::{Cmd, TrayMenu, View};
use session::{Change, Choice, Fuse, Session};
use std::cell::RefCell;
use std::time::Instant;
use thermal::Thermal;
use tray_icon::menu::{MenuEvent, MenuId};
use windows::core::w;
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HANDLE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Power::{RegisterPowerSettingNotification, POWERBROADCAST_SETTING};
use windows::Win32::System::SystemServices::GUID_LIDSWITCH_STATE_CHANGE;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::*;

const TIMER_ID: usize = 1;
/// Read sensors every N one-second ticks.
const THERMAL_EVERY: u32 = 5;

struct App {
    hwnd: HWND,
    session: Session,
    fuse: Fuse,
    thermal: Thermal,
    menu: TrayMenu,
    /// Last event worth showing while idle (heat-fuse trip, start failure).
    status: Option<String>,
    lid_closed: bool,
    ticks: u32,
    temp: Option<f32>,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// Runs `f` on the app state; skipped if it is already borrowed (re-entrant message during a modal loop).
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|a| a.try_borrow_mut().ok()?.as_mut().map(f))
}

impl App {
    fn select(&mut self, choice: Choice) {
        match self.session.select(choice, Instant::now()) {
            Change::Started => match awake::start() {
                Ok(()) => {
                    self.status = None;
                    self.fuse.reset();
                    self.ticks = 0;
                    unsafe { SetTimer(Some(self.hwnd), TIMER_ID, 1000, None) };
                }
                Err(e) => {
                    self.session.stop();
                    self.status = Some(format!("Couldn't keep awake: {e}"));
                }
            },
            Change::Stopped => self.stopped(),
            Change::Moved | Change::Nothing => {}
        }
    }

    fn stop(&mut self) {
        if self.session.stop() == Change::Stopped {
            self.stopped();
        }
    }

    fn stopped(&mut self) {
        awake::stop();
        self.temp = None;
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_ID);
        }
    }

    fn tick(&mut self) {
        let now = Instant::now();
        if self.session.tick(now) == Change::Stopped {
            self.stopped();
            self.refresh();
            if self.lid_closed {
                awake::sleep_now();
            }
            return;
        }
        self.ticks += 1;
        if self.session.is_active() && self.thermal.available() && self.ticks % THERMAL_EVERY == 0 {
            let readings = self.thermal.read();
            self.temp = readings.iter().map(|r| r.celsius).reduce(f32::max);
            if reg::heat_fuse() {
                if let Some(reason) = self.fuse.check(&readings, now) {
                    self.stop();
                    self.status = Some(format!("Put to sleep by heat fuse · {reason}"));
                    self.refresh();
                    awake::sleep_now();
                    return;
                }
            }
        }
        self.refresh();
    }

    fn refresh(&self) {
        let view = View {
            status: self.status.as_deref(),
            fuse_temp: self.thermal.available().then_some(self.temp),
            fuse_on: reg::heat_fuse(),
            login_on: reg::autostart_enabled(),
            light_taskbar: reg::light_taskbar(),
        };
        self.menu.update(&self.session, Instant::now(), &view);
    }
}

fn on_menu(id: MenuId) {
    let Some(cmd) = with_app(|a| a.menu.cmd(&id)).flatten() else { return };
    match cmd {
        Cmd::Preset(i) => {
            with_app(|a| a.select(Choice::Preset(i)));
        }
        Cmd::Custom => {
            let custom_active = with_app(|a| matches!(a.session.choice(), Some(Choice::Custom(_))));
            if custom_active == Some(true) {
                with_app(App::stop);
            } else if let Some(d) = dialog::ask_custom() {
                // No borrow is held while the dialog runs its own message loop.
                with_app(|a| a.select(Choice::Custom(d)));
            }
        }
        Cmd::Fuse => reg::set_heat_fuse(!reg::heat_fuse()),
        Cmd::Login => {
            if let Err(e) = reg::set_autostart(!reg::autostart_enabled()) {
                with_app(|a| a.status = Some(format!("Couldn't change start at login: {e}")));
            }
        }
        Cmd::Exit => {
            with_app(App::stop);
            unsafe { PostQuitMessage(0) };
            return;
        }
    }
    with_app(|a| a.refresh());
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TIMER if wp.0 == TIMER_ID => {
            with_app(App::tick);
        }
        WM_POWERBROADCAST if wp.0 == PBT_POWERSETTINGCHANGE as usize => {
            let s = &*(lp.0 as *const POWERBROADCAST_SETTING);
            if s.PowerSetting == GUID_LIDSWITCH_STATE_CHANGE {
                with_app(|a| a.lid_closed = s.Data[0] == 0);
            }
        }
        // Logoff, restart, shutdown.
        WM_ENDSESSION if wp.0 != 0 => {
            with_app(App::stop);
        }
        WM_SETTINGCHANGE => {
            with_app(|a| a.refresh());
        }
        _ => {}
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

fn main() {
    if std::env::args().any(|a| a == "--restore") {
        awake::recover_if_needed();
        return;
    }
    unsafe {
        // Single instance; the handle lives until the process exits.
        let _mutex = CreateMutexW(None, true, w!("Local\\coffee-bar"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return;
        }
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    awake::recover_if_needed();
    std::panic::set_hook(Box::new(|_| awake::stop()));
    if reg::autostart_enabled() {
        let _ = reg::set_autostart(true); // keeps the Run path current if the exe moved
    }

    let hwnd = unsafe {
        let instance = GetModuleHandleW(None).expect("module handle");
        let class = w!("coffee-bar");
        RegisterClassW(&WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        });
        // A hidden top-level window (not message-only) so it receives WM_ENDSESSION and WM_SETTINGCHANGE.
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("coffee-bar"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .expect("hidden window");
        let _ = RegisterPowerSettingNotification(HANDLE(hwnd.0), &GUID_LIDSWITCH_STATE_CHANGE, DEVICE_NOTIFY_WINDOW_HANDLE);
        hwnd
    };

    let app = App {
        hwnd,
        session: Session::default(),
        fuse: Fuse::default(),
        thermal: Thermal::new(),
        menu: TrayMenu::new(),
        status: None,
        lid_closed: false,
        ticks: 0,
        temp: None,
    };
    app.refresh();
    APP.with(|a| *a.borrow_mut() = Some(app));

    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
            while let Ok(event) = MenuEvent::receiver().try_recv() {
                on_menu(event.id);
            }
        }
    }
    with_app(App::stop);
}
