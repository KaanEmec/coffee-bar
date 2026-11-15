//! Tray icon and its menu (Menu F). Presentation only: no system changes here.

use crate::duration;
use crate::session::{Choice, Session, PRESETS};
use std::cell::Cell;
use std::time::Instant;
use tray_icon::menu::{CheckMenuItem, Icon as MenuIcon, IconMenuItem, Menu, MenuId, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

pub enum Cmd {
    Preset(usize),
    Custom,
    Fuse,
    Login,
    Exit,
}

/// Everything the menu shows besides the session itself.
pub struct View<'a> {
    /// Shown on the countdown line while idle, instead of "Not keeping awake".
    pub status: Option<&'a str>,
    /// None = no sensor; Some(None) = sensor but no reading yet; Some(Some(c)) = hottest reading.
    pub fuse_temp: Option<Option<f32>>,
    pub fuse_on: bool,
    pub login_on: bool,
    pub light_taskbar: bool,
}

pub struct TrayMenu {
    tray: TrayIcon,
    countdown: IconMenuItem,
    keep: Submenu,
    presets: Vec<CheckMenuItem>,
    custom: CheckMenuItem,
    fuse: CheckMenuItem,
    login: CheckMenuItem,
    exit: IconMenuItem,
    /// (active, light taskbar) of the icon currently shown.
    shown: Cell<Option<(bool, bool)>>,
}

fn rgba(bytes: &[u8]) -> (Vec<u8>, u32, u32) {
    (bytes.to_vec(), 32, 32)
}

fn tray_icon(active: bool, light_taskbar: bool) -> Icon {
    let bytes: &[u8] = match (active, light_taskbar) {
        (false, true) => include_bytes!("../icons/idle-light.rgba"),
        (false, false) => include_bytes!("../icons/idle-dark.rgba"),
        (true, true) => include_bytes!("../icons/active-light.rgba"),
        (true, false) => include_bytes!("../icons/active-dark.rgba"),
    };
    let (v, w, h) = rgba(bytes);
    Icon::from_rgba(v, w, h).expect("tray icon")
}

fn menu_icon(bytes: &[u8]) -> Option<MenuIcon> {
    let (v, w, h) = rgba(bytes);
    MenuIcon::from_rgba(v, w, h).ok()
}

impl TrayMenu {
    pub fn new() -> Self {
        let countdown = IconMenuItem::new("Not keeping awake", false, menu_icon(include_bytes!("../icons/timer.rgba")), None);
        let presets: Vec<_> = PRESETS.iter().map(|(label, _)| CheckMenuItem::new(*label, true, false, None)).collect();
        let custom = CheckMenuItem::new("Custom…", true, false, None);
        let keep = Submenu::new("Keep awake", true);
        for p in &presets {
            keep.append(p).unwrap();
        }
        keep.append_items(&[&PredefinedMenuItem::separator(), &custom]).unwrap();
        keep.set_icon(menu_icon(include_bytes!("../icons/cup.rgba")));
        let fuse = CheckMenuItem::new("Heat fuse", true, false, None);
        let login = CheckMenuItem::new("Start at login", true, false, None);
        let exit = IconMenuItem::new("Exit", true, menu_icon(include_bytes!("../icons/exit.rgba")), None);

        let menu = Menu::new();
        menu.append_items(&[
            &countdown,
            &PredefinedMenuItem::separator(),
            &keep,
            &PredefinedMenuItem::separator(),
            &fuse,
            &login,
            &PredefinedMenuItem::separator(),
            &exit,
        ])
        .unwrap();

        let tray = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_menu_on_left_click(true)
            .with_tooltip("coffee-bar")
            .with_icon(tray_icon(false, false))
            .build()
            .expect("tray icon");
        TrayMenu { tray, countdown, keep, presets, custom, fuse, login, exit, shown: Cell::new(None) }
    }

    pub fn cmd(&self, id: &MenuId) -> Option<Cmd> {
        if let Some(i) = self.presets.iter().position(|p| p.id() == id) {
            return Some(Cmd::Preset(i));
        }
        [
            (self.custom.id(), Cmd::Custom),
            (self.fuse.id(), Cmd::Fuse),
            (self.login.id(), Cmd::Login),
            (self.exit.id(), Cmd::Exit),
        ]
        .into_iter()
        .find_map(|(item, cmd)| (item == id).then_some(cmd))
    }

    pub fn update(&self, s: &Session, now: Instant, v: &View) {
        let choice = s.choice();
        let line = match s.remaining(now) {
            Some(left) => format!("Awake · {} left", duration::hms(left)),
            None => v.status.unwrap_or("Not keeping awake").to_string(),
        };
        self.countdown.set_text(&line);
        let _ = self.tray.set_tooltip(Some(format!("coffee-bar — {line}")));
        let key = (choice.is_some(), v.light_taskbar);
        if self.shown.replace(Some(key)) != Some(key) {
            let _ = self.tray.set_icon(Some(tray_icon(key.0, key.1)));
        }

        self.keep.set_text(match choice {
            Some(c) => format!("Keep awake · {}", c.label()),
            None => "Keep awake".to_string(),
        });
        for (i, p) in self.presets.iter().enumerate() {
            p.set_checked(choice == Some(Choice::Preset(i)));
        }
        match choice {
            Some(Choice::Custom(d)) => {
                self.custom.set_text(format!("Custom ({})", duration::short(d)));
                self.custom.set_checked(true);
            }
            _ => {
                self.custom.set_text("Custom…");
                self.custom.set_checked(false);
            }
        }

        let fuse_text = match v.fuse_temp {
            None => "Heat fuse · no sensor".to_string(),
            Some(Some(c)) if s.is_active() => format!("Heat fuse · {c:.0}°C"),
            Some(_) => "Heat fuse".to_string(),
        };
        self.fuse.set_text(fuse_text);
        self.fuse.set_enabled(v.fuse_temp.is_some());
        self.fuse.set_checked(v.fuse_on && v.fuse_temp.is_some());
        self.login.set_checked(v.login_on);
    }
}
