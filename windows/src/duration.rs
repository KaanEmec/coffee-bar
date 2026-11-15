//! Parse "45", "90m", "2h", "1h30m", "1:30" and format durations for the menu.

use std::time::Duration;

const MIN_SECS: u64 = 60;
const MAX_SECS: u64 = 7 * 24 * 3600;

/// Plain numbers are minutes. Returns None outside 1 minute ..= 7 days.
pub fn parse(input: &str) -> Option<Duration> {
    let s: String = input.trim().to_ascii_lowercase().split_whitespace().collect();
    if s.is_empty() {
        return None;
    }
    let num = |t: &str| -> Option<u64> {
        (!t.is_empty() && t.len() <= 6 && t.bytes().all(|b| b.is_ascii_digit())).then(|| t.parse().ok())?
    };
    let secs = if let Some((h, m)) = s.split_once(':') {
        let (h, m) = (num(h)?, num(m)?);
        if m >= 60 {
            return None;
        }
        h * 3600 + m * 60
    } else if let Some(n) = num(&s) {
        n * 60
    } else {
        let (mut total, mut digits, mut last_unit) = (0, String::new(), ' ');
        for c in s.chars() {
            if c.is_ascii_digit() {
                digits.push(c);
                continue;
            }
            let unit = match c {
                'h' if last_unit == ' ' => 3600,
                'm' if last_unit != 'm' => 60,
                _ => return None,
            };
            total += num(&digits)? * unit;
            digits.clear();
            last_unit = c;
        }
        if !digits.is_empty() {
            return None;
        }
        total
    };
    (MIN_SECS..=MAX_SECS).contains(&secs).then(|| Duration::from_secs(secs))
}

/// "1:23:45" (hours not padded, can exceed 24).
pub fn hms(d: Duration) -> String {
    let s = d.as_secs();
    format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
}

/// "45m", "2h", "3h 15m".
pub fn short(d: Duration) -> String {
    let (h, m) = (d.as_secs() / 3600, d.as_secs() / 60 % 60);
    match (h, m) {
        (0, m) => format!("{m}m"),
        (h, 0) => format!("{h}h"),
        (h, m) => format!("{h}h {m}m"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mins(s: &str) -> Option<u64> {
        parse(s).map(|d| d.as_secs() / 60)
    }

    #[test]
    fn valid() {
        assert_eq!(mins("45"), Some(45));
        assert_eq!(mins("90m"), Some(90));
        assert_eq!(mins("2h"), Some(120));
        assert_eq!(mins("1h30m"), Some(90));
        assert_eq!(mins(" 1h 30m "), Some(90));
        assert_eq!(mins("1:30"), Some(90));
        assert_eq!(mins("1"), Some(1));
        assert_eq!(mins("168h"), Some(168 * 60));
    }

    #[test]
    fn invalid() {
        for s in ["", "0", "-5", "abc", "8d", "1h30", "1:60", "169h", "m", "2m1h", "1h1h", "99999999"] {
            assert_eq!(parse(s), None, "{s:?} should be rejected");
        }
    }

    #[test]
    fn formatting() {
        assert_eq!(hms(Duration::from_secs(5025)), "1:23:45");
        assert_eq!(hms(Duration::from_secs(59)), "0:00:59");
        assert_eq!(short(Duration::from_secs(45 * 60)), "45m");
        assert_eq!(short(Duration::from_secs(7200)), "2h");
        assert_eq!(short(Duration::from_secs(3 * 3600 + 15 * 60)), "3h 15m");
    }
}
