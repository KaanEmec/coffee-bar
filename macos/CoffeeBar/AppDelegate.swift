import AppKit
import ServiceManagement

/// Wires TrayMenu -> Session -> AwakeController, runs the 1 s tick and the heat fuse.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let heatFuseKey = "heatFuse"

    // Lazy so the unit-test host never touches IOKit or the helper.
    private lazy var awake = AwakeController()
    private lazy var thermal = ThermalMonitor()
    private lazy var fuse = Fuse(isAppleSilicon: thermal.isAppleSilicon)
    private var session = Session()
    private var tray: TrayMenu?
    private var timer: Timer?
    private var ticks = 0
    private var status: String?       // last error or heat-fuse trip, shown while idle
    private var temperature: String?  // "CPU 72°C", only while active
    private var startAtLogin = false
    private var needsApproval = false

    private var heatFuseOn: Bool { UserDefaults.standard.bool(forKey: Self.heatFuseKey) }

    // No MainMenu nib, so create the application and its delegate here.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        UserDefaults.standard.register(defaults: [Self.heatFuseKey: true])
        awake.recoverIfNeeded()

        let tray = TrayMenu()
        tray.onAction = { [weak self] in self?.handle($0) }
        tray.onWillOpen = { [weak self] in
            self?.refreshSystemState()
            self?.refresh()
        }
        self.tray = tray

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)

        refreshSystemState()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard tray != nil else { return } // test host
        goIdle()
    }

    @objc private func willPowerOff(_ notification: Notification) {
        goIdle()
    }

    // MARK: - Menu actions

    private func handle(_ action: TrayMenu.Action) {
        switch action {
        case .preset(let i):
            select(.preset(i))
        case .custom:
            if case .custom? = session.choice {
                goIdle() // clicking the checked item stops
            } else if let duration = CustomPrompt.ask() {
                select(.custom(duration))
            }
        case .enableLidMode:
            awake.openApprovalSettings()
        case .heatFuse:
            UserDefaults.standard.set(!heatFuseOn, forKey: Self.heatFuseKey)
            fuse.reset()
        case .startAtLogin:
            toggleStartAtLogin()
        case .exit:
            goIdle()
            NSApp.terminate(nil)
        }
        refresh()
    }

    private func select(_ choice: Session.Choice) {
        switch session.select(choice, now: Date()) {
        case .started:
            status = nil
            switch awake.start() {
            case .success:
                fuse.reset()
                ticks = 0
                // .common mode keeps the countdown ticking while the menu is open.
                let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick),
                                  userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            case .failure(let error):
                goIdle()
                status = "Couldn't keep awake: \(error.message)"
            }
        case .stopped:
            goIdle()
        case .moved, .nothing:
            break
        }
    }

    private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            status = "Couldn't change Start at login: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshSystemState()
    }

    // MARK: - Tick and heat fuse

    @objc private func tick() {
        let now = Date()
        if session.tick(now: now) == .stopped {
            goIdle()
            if awake.isLidClosed() { awake.sleepNow() }
        } else {
            ticks += 1
            if ticks % 5 == 0 { checkHeat(now: now) }
        }
        refresh()
    }

    private func checkHeat(now: Date) {
        let readings = thermal.read()
        temperature = readings.filter(Fuse.isPlausible).max { $0.celsius < $1.celsius }.map(Fuse.label)
        guard heatFuseOn,
              let reason = fuse.check(readings, critical: thermal.thermalCritical, now: now) else { return }
        goIdle()
        status = "Put to sleep by heat fuse · \(reason)"
        awake.sleepNow()
    }

    // MARK: - State

    /// Session -> idle and restore every system change. Safe to call any number of times.
    private func goIdle() {
        session.stop()
        timer?.invalidate()
        timer = nil
        temperature = nil
        awake.stop()
    }

    /// Things the user can change in System Settings while the app runs.
    private func refreshSystemState() {
        startAtLogin = SMAppService.mainApp.status == .enabled
        needsApproval = awake.lidMode == .needsApproval
    }

    private func refresh() {
        tray?.update(choice: session.choice, remaining: session.remaining(now: Date()), status: status,
                     heatFuse: heatFuseOn, temperature: temperature,
                     startAtLogin: startAtLogin, needsApproval: needsApproval)
    }
}
