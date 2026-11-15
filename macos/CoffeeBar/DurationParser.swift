import Foundation

/// Parse "45", "90m", "2h", "1h30m", "1:30" and format durations for the menu.
/// Same rules as code/windows/src/duration.rs.
enum DurationParser {
    static let range: ClosedRange<TimeInterval> = 60...(7 * 24 * 3600)

    /// Plain numbers are minutes. Returns nil outside 1 minute ... 7 days.
    static func parse(_ input: String) -> TimeInterval? {
        let s = input.lowercased().filter { !$0.isWhitespace }
        func number<S: StringProtocol>(_ t: S) -> Int? {
            guard !t.isEmpty, t.count <= 6, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(t))
        }

        let seconds: Int
        if let colon = s.firstIndex(of: ":") {
            guard let h = number(s[..<colon]), let m = number(s[s.index(after: colon)...]), m < 60 else {
                return nil
            }
            seconds = h * 3600 + m * 60
        } else if let n = number(s) {
            seconds = n * 60
        } else {
            var total = 0, digits = "", lastUnit: Character = " "
            for c in s {
                if c.isASCII && c.isNumber {
                    digits.append(c)
                    continue
                }
                let unit: Int
                switch c {
                case "h" where lastUnit == " ": unit = 3600
                case "m" where lastUnit != "m": unit = 60
                default: return nil
                }
                guard let n = number(digits) else { return nil }
                total += n * unit
                digits = ""
                lastUnit = c
            }
            guard digits.isEmpty else { return nil }
            seconds = total
        }
        let t = TimeInterval(seconds)
        return range.contains(t) ? t : nil
    }

    /// "1:23:45" (hours not padded, can exceed 24).
    static func hms(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%ld:%02ld:%02ld", s / 3600, s / 60 % 60, s % 60)
    }

    /// "45m", "2h", "3h 15m".
    static func short(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = Int(t) / 60 % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }
}
