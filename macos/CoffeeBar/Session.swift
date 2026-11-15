import Foundation

/// What the user chose and when it ends. No IOKit or XPC calls here.
struct Session {
    static let presets: [(label: String, seconds: TimeInterval)] = [
        ("30 minutes", 30 * 60),
        ("1 hour", 3600),
        ("2 hours", 2 * 3600),
        ("4 hours", 4 * 3600),
        ("8 hours", 8 * 3600),
        ("12 hours", 12 * 3600),
        ("24 hours", 24 * 3600),
    ]

    enum Choice: Equatable {
        case preset(Int)
        case custom(TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .preset(let i): return Session.presets[i].seconds
            case .custom(let d): return d
            }
        }

        /// "8 hours", or "3h 15m" for a custom duration.
        var label: String {
            switch self {
            case .preset(let i): return Session.presets[i].label
            case .custom(let d): return DurationParser.short(d)
            }
        }
    }

    /// What the caller must do to the system after a session change.
    enum Change {
        case started  // idle -> active: apply system changes
        case moved    // active -> active with a new deadline: nothing to apply
        case stopped  // active -> idle: restore system changes
        case nothing
    }

    /// The deadline is wall-clock time, so the countdown stays right across sleep.
    private var active: (choice: Choice, deadline: Date)?

    var choice: Choice? { active?.choice }
    var isActive: Bool { active != nil }

    /// Selecting the active choice again stops; anything else (re)starts the countdown.
    mutating func select(_ choice: Choice, now: Date) -> Change {
        guard let current = active else {
            active = (choice, now + choice.duration)
            return .started
        }
        if current.choice == choice { return stop() }
        active = (choice, now + choice.duration)
        return .moved
    }

    @discardableResult
    mutating func stop() -> Change {
        defer { active = nil }
        return active == nil ? .nothing : .stopped
    }

    func remaining(now: Date) -> TimeInterval? {
        active.map { max(0, $0.deadline.timeIntervalSince(now)) }
    }

    /// Stops when the deadline has passed.
    mutating func tick(now: Date) -> Change {
        guard let active, now >= active.deadline else { return .nothing }
        return stop()
    }
}

/// Heat fuse: trips when one sensor stays at or above its limit for its whole hold time.
/// See files/ARCHITECTURE.md#heat-fuse.
struct Fuse {
    let isAppleSilicon: Bool
    private var hotSince: [String: Date] = [:]

    init(isAppleSilicon: Bool) {
        self.isAppleSilicon = isAppleSilicon
    }

    /// "CPU 72°C"
    static func label(_ r: Reading) -> String {
        "\(name(r.sensor)) \(Int(r.celsius.rounded()))°C"
    }

    mutating func reset() {
        hotSince = [:]
    }

    /// Returns the trip reason, e.g. "CPU 111°C for 30 s". Implausible readings are ignored:
    /// they never trip the fuse and never reset a timer. A missing sensor resets nothing either.
    mutating func check(_ readings: [Reading], critical: Bool, now: Date) -> String? {
        var probes: [(key: String, hot: Bool, hold: TimeInterval, text: String)] = []
        for r in readings where r.celsius > 0 && r.celsius <= 150 { // else a sensor glitch
            let (limit, hold) = limits(r.sensor)
            probes.append((Fuse.name(r.sensor), r.celsius >= limit, hold, Fuse.label(r)))
        }
        probes.append(("thermal state", critical, 60, "thermal state critical"))

        for p in probes {
            guard p.hot else {
                hotSince[p.key] = nil
                continue
            }
            let since = hotSince[p.key] ?? now
            hotSince[p.key] = since
            if now.timeIntervalSince(since) >= p.hold {
                reset()
                return "\(p.text) for \(Int(p.hold)) s"
            }
        }
        return nil
    }

    /// (limit °C, hold time) per sensor.
    private func limits(_ sensor: Sensor) -> (Double, TimeInterval) {
        switch sensor {
        case .cpuDie: return isAppleSilicon ? (110, 30) : (100, 120)
        case .battery: return (55, 60)
        }
    }

    private static func name(_ sensor: Sensor) -> String {
        switch sensor {
        case .cpuDie: return "CPU"
        case .battery: return "battery"
        }
    }
}
