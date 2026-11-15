//! What the user chose and when it ends, plus the heat-fuse trip rule. No Win32 calls here.

use crate::duration;
use crate::thermal::{Reading, Sensor};
use std::time::{Duration, Instant};

pub const PRESETS: [(&str, u64); 7] = [
    ("30 minutes", 30 * 60),
    ("1 hour", 3600),
    ("2 hours", 2 * 3600),
    ("4 hours", 4 * 3600),
    ("8 hours", 8 * 3600),
    ("12 hours", 12 * 3600),
    ("24 hours", 24 * 3600),
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Choice {
    Preset(usize),
    Custom(Duration),
}

impl Choice {
    pub fn duration(self) -> Duration {
        match self {
            Choice::Preset(i) => Duration::from_secs(PRESETS[i].1),
            Choice::Custom(d) => d,
        }
    }

    pub fn label(self) -> String {
        match self {
            Choice::Preset(i) => PRESETS[i].0.to_string(),
            Choice::Custom(d) => duration::short(d),
        }
    }
}

/// What the caller must do to the system after a session change.
#[derive(Debug, PartialEq)]
pub enum Change {
    /// Idle -> active: apply system changes.
    Started,
    /// Active -> active with a new deadline: nothing to apply.
    Moved,
    /// Active -> idle: restore system changes.
    Stopped,
    Nothing,
}

#[derive(Default)]
pub struct Session {
    active: Option<(Choice, Instant)>,
}

impl Session {
    pub fn choice(&self) -> Option<Choice> {
        self.active.map(|(c, _)| c)
    }

    pub fn is_active(&self) -> bool {
        self.active.is_some()
    }

    /// Selecting the active choice again stops; anything else (re)starts the countdown.
    pub fn select(&mut self, choice: Choice, now: Instant) -> Change {
        match self.active {
            Some((c, _)) if c == choice => self.stop(),
            Some(_) => {
                self.active = Some((choice, now + choice.duration()));
                Change::Moved
            }
            None => {
                self.active = Some((choice, now + choice.duration()));
                Change::Started
            }
        }
    }

    pub fn stop(&mut self) -> Change {
        match self.active.take() {
            Some(_) => Change::Stopped,
            None => Change::Nothing,
        }
    }

    pub fn remaining(&self, now: Instant) -> Option<Duration> {
        self.active.map(|(_, end)| end.saturating_duration_since(now))
    }

    /// Stops when the deadline has passed.
    pub fn tick(&mut self, now: Instant) -> Change {
        match self.active {
            Some((_, end)) if now >= end => self.stop(),
            _ => Change::Nothing,
        }
    }
}

/// (limit °C, hold time) per sensor. See files/ARCHITECTURE.md#heat-fuse.
fn limit(sensor: Sensor) -> (f32, Duration) {
    match sensor {
        Sensor::Zone => (98.0, Duration::from_secs(60)),
        Sensor::Battery => (55.0, Duration::from_secs(60)),
    }
}

/// Trips when one sensor stays at or above its limit for its whole hold time.
#[derive(Default)]
pub struct Fuse {
    hot_since: Vec<(Sensor, Instant)>,
}

impl Fuse {
    pub fn reset(&mut self) {
        self.hot_since.clear();
    }

    /// Returns the trip reason, e.g. "battery 56°C for 60 s". Implausible readings are ignored.
    pub fn check(&mut self, readings: &[Reading], now: Instant) -> Option<String> {
        for r in readings.iter().filter(|r| r.celsius > 0.0 && r.celsius <= 150.0) {
            let (max, hold) = limit(r.sensor);
            let pos = self.hot_since.iter().position(|(s, _)| *s == r.sensor);
            match (r.celsius >= max, pos) {
                (true, None) => self.hot_since.push((r.sensor, now)),
                (true, Some(i)) if now - self.hot_since[i].1 >= hold => {
                    self.reset();
                    let name = match r.sensor {
                        Sensor::Zone => "thermal zone",
                        Sensor::Battery => "battery",
                    };
                    return Some(format!("{name} {:.0}°C for {} s", r.celsius, hold.as_secs()));
                }
                (false, Some(i)) => {
                    self.hot_since.remove(i);
                }
                _ => {}
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn select_toggle_and_move() {
        let t = Instant::now();
        let mut s = Session::default();
        assert_eq!(s.select(Choice::Preset(1), t), Change::Started);
        assert_eq!(s.remaining(t), Some(secs(3600)));
        assert_eq!(s.select(Choice::Preset(0), t + secs(10)), Change::Moved);
        assert_eq!(s.remaining(t + secs(10)), Some(secs(1800)));
        assert_eq!(s.select(Choice::Preset(0), t + secs(20)), Change::Stopped);
        assert!(!s.is_active());
        assert_eq!(s.stop(), Change::Nothing);
    }

    #[test]
    fn custom_and_deadline() {
        let t = Instant::now();
        let mut s = Session::default();
        s.select(Choice::Custom(secs(60)), t);
        assert_eq!(s.choice().unwrap().label(), "1m");
        assert_eq!(s.tick(t + secs(59)), Change::Nothing);
        assert_eq!(s.tick(t + secs(60)), Change::Stopped);
        assert_eq!(s.choice(), None);
    }

    fn zone(c: f32) -> Reading {
        Reading { sensor: Sensor::Zone, celsius: c }
    }

    #[test]
    fn fuse_needs_whole_hold_time() {
        let t = Instant::now();
        let mut f = Fuse::default();
        assert_eq!(f.check(&[zone(99.0)], t), None);
        assert_eq!(f.check(&[zone(99.0)], t + secs(55)), None);
        assert!(f.check(&[zone(101.0)], t + secs(60)).unwrap().contains("101°C"));
    }

    #[test]
    fn fuse_resets_when_cool_and_ignores_junk() {
        let t = Instant::now();
        let mut f = Fuse::default();
        f.check(&[zone(99.0)], t);
        f.check(&[zone(90.0)], t + secs(30));
        assert_eq!(f.check(&[zone(99.0)], t + secs(65)), None);
        // Implausible values and missing sensors neither trip nor reset.
        assert_eq!(f.check(&[zone(400.0), zone(-1.0)], t + secs(100)), None);
        assert_eq!(f.check(&[], t + secs(110)), None);
        assert!(f.check(&[zone(99.0)], t + secs(125)).is_some());
    }

    #[test]
    fn battery_limit() {
        let t = Instant::now();
        let mut f = Fuse::default();
        let bat = |c| Reading { sensor: Sensor::Battery, celsius: c };
        f.check(&[bat(56.0), zone(60.0)], t);
        assert!(f.check(&[bat(56.0)], t + secs(60)).unwrap().starts_with("battery"));
    }
}
