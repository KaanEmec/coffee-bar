import XCTest
@testable import CoffeeBar

final class SessionTests: XCTestCase {
    // A round reference date keeps the Date arithmetic exact.
    private let t = Date(timeIntervalSinceReferenceDate: 0)

    func testSelectToggleAndMove() {
        var s = Session()
        XCTAssertEqual(s.select(.preset(1), now: t), .started)
        XCTAssertEqual(s.remaining(now: t), 3600)
        XCTAssertEqual(s.select(.preset(0), now: t + 10), .moved)
        XCTAssertEqual(s.remaining(now: t + 10), 1800)
        XCTAssertEqual(s.select(.preset(0), now: t + 20), .stopped)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.remaining(now: t + 20))
        XCTAssertEqual(s.stop(), .nothing)
    }

    func testCustomAndDeadline() {
        var s = Session()
        _ = s.select(.custom(60), now: t)
        XCTAssertEqual(s.choice?.label, "1m")
        XCTAssertEqual(s.tick(now: t + 59), .nothing)
        XCTAssertEqual(s.tick(now: t + 60), .stopped)
        XCTAssertNil(s.choice)
    }

    func testLabels() {
        XCTAssertEqual(Session.Choice.preset(4).label, "8 hours")
        XCTAssertEqual(Session.Choice.custom(3 * 3600 + 15 * 60).label, "3h 15m")
    }

    private func cpu(_ c: Double) -> Reading { Reading(sensor: .cpuDie, celsius: c) }
    private func battery(_ c: Double) -> Reading { Reading(sensor: .battery, celsius: c) }

    func testFuseNeedsWholeHoldTime() {
        var f = Fuse(isAppleSilicon: true)
        XCTAssertNil(f.check([cpu(111)], critical: false, now: t))
        XCTAssertNil(f.check([cpu(111)], critical: false, now: t + 25))
        XCTAssertEqual(f.check([cpu(112)], critical: false, now: t + 30), "CPU 112°C for 30 s")
    }

    func testFuseResetsWhenCoolAndIgnoresJunk() {
        var f = Fuse(isAppleSilicon: true)
        _ = f.check([cpu(111)], critical: false, now: t)
        _ = f.check([cpu(90)], critical: false, now: t + 15)
        XCTAssertNil(f.check([cpu(111)], critical: false, now: t + 40))
        // Implausible values and missing sensors neither trip nor reset.
        XCTAssertNil(f.check([cpu(400), cpu(-1)], critical: false, now: t + 50))
        XCTAssertNil(f.check([], critical: false, now: t + 60))
        XCTAssertNotNil(f.check([cpu(111)], critical: false, now: t + 70))
    }

    func testIntelLimit() {
        var f = Fuse(isAppleSilicon: false)
        XCTAssertNil(f.check([cpu(105)], critical: false, now: t))
        XCTAssertNil(f.check([cpu(105)], critical: false, now: t + 115))
        XCTAssertEqual(f.check([cpu(105)], critical: false, now: t + 120), "CPU 105°C for 120 s")

        var cool = Fuse(isAppleSilicon: false)
        XCTAssertNil(cool.check([cpu(99)], critical: false, now: t))
        XCTAssertNil(cool.check([cpu(99)], critical: false, now: t + 600))
    }

    func testBatteryLimit() {
        var f = Fuse(isAppleSilicon: true)
        _ = f.check([battery(56), cpu(60)], critical: false, now: t)
        XCTAssertEqual(f.check([battery(56)], critical: false, now: t + 60), "battery 56°C for 60 s")
    }

    func testThermalStateCritical() {
        var f = Fuse(isAppleSilicon: true)
        XCTAssertNil(f.check([], critical: true, now: t))
        XCTAssertNil(f.check([], critical: false, now: t + 30)) // resets
        XCTAssertNil(f.check([], critical: true, now: t + 40))
        XCTAssertNil(f.check([], critical: true, now: t + 99))
        XCTAssertEqual(f.check([], critical: true, now: t + 100), "thermal state critical for 60 s")
        // A trip resets every timer.
        XCTAssertNil(f.check([], critical: true, now: t + 101))
    }

    func testTemperatureLabel() {
        XCTAssertEqual(Fuse.label(cpu(71.6)), "CPU 72°C")
    }
}
