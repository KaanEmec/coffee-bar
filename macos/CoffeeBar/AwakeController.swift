import Foundation
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

struct AwakeError: Error { let message: String }

/// Idle-sleep assertion plus the root helper for closed-lid mode. Use from the main thread only.
final class AwakeController {
    enum LidMode { case available, needsApproval, unavailable }

    private let daemon = SMAppService.daemon(plistName: helperPlistName)
    private var triedRegister = false
    private var assertionID: IOPMAssertionID?
    private var sleepDisabled = false        // we told the helper `disablesleep 1`
    private var connection: NSXPCConnection? // kept open while the app runs; its loss tells the helper to clean up

    var lidMode: LidMode {
        if !triedRegister {
            triedRegister = true
            registerHelper()
        }
        switch daemon.status {
        case .enabled: return .available
        case .requiresApproval: return .needsApproval
        default: return .unavailable
        }
    }

    func start() -> Result<Void, AwakeError> {
        if assertionID == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "coffee-bar keeping awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else {
                return .failure(AwakeError(message: "Couldn't block idle sleep (IOReturn \(result))."))
            }
            assertionID = id
        }
        if !sleepDisabled && lidMode == .available {
            let applied = callHelper({ $0.setSleepDisabled(true, reply: $1) })
            guard applied == true else {
                // Roll back; on a timeout the change may have been applied anyway.
                _ = callHelper({ $0.setSleepDisabled(false, reply: $1) })
                releaseAssertion()
                return .failure(AwakeError(message: applied == nil
                    ? "The closed-lid helper didn't respond."
                    : "The closed-lid helper couldn't change the sleep setting."))
            }
            sleepDisabled = true
        }
        return .success(())
    }

    func stop() {
        if sleepDisabled {
            sleepDisabled = false
            _ = callHelper({ $0.setSleepDisabled(false, reply: $1) })
        }
        releaseAssertion()
    }

    func recoverIfNeeded() {
        guard lidMode == .available else { return }
        _ = callHelper({ $0.setSleepDisabled(false, reply: $1) })
    }

    func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (state as? Bool) ?? false
    }

    func sleepNow() {
        // nil = sent but no reply in time: don't also run the fallback, it could re-sleep after wake.
        if lidMode == .available, callHelper({ $0.sleepNow(reply: $1) }) != false { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do { try process.run() } catch { NSLog("coffee-bar: pmset sleepnow: \(error)") }
    }

    // MARK: - Private

    /// Registers the helper on first use, and again on the first launch of a new app build:
    /// launchd keeps the launch constraint of the build it registered and refuses to start an
    /// updated helper (EX_CONFIG) until it is re-registered. macOS then asks for approval again.
    private func registerHelper() {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = "\(info["CFBundleShortVersionString"] ?? "")-\(info["CFBundleVersion"] ?? "")"
        let key = "helperRegisteredBuild"
        do {
            switch daemon.status {
            case .notRegistered, .notFound: // a never-registered daemon reports .notFound on macOS 27
                try daemon.register()
            default:
                guard UserDefaults.standard.string(forKey: key) != build else { break }
                try? daemon.unregister()
                try daemon.register()
            }
        } catch {
            NSLog("coffee-bar: helper register: \(error)") // also thrown while approval is pending
        }
        UserDefaults.standard.set(build, forKey: key)
    }

    private func releaseAssertion() {
        if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    /// Sends one message and waits for the reply. Returns the helper's result, false on an XPC
    /// error, nil on timeout. Replies arrive on an XPC queue, so waiting on main can't deadlock.
    /// An XPC error is retried once: the message may have reached a helper that was just exiting
    /// (its idle exit after a RunAtLoad start), and launchd starts a fresh one for the retry.
    private func callHelper(_ send: (HelperProtocol, @escaping (Bool) -> Void) -> Void) -> Bool? {
        for attempt in 1...2 {
            let done = DispatchSemaphore(value: 0)
            var ok = false
            var failed = false
            let proxy = helperConnection().remoteObjectProxyWithErrorHandler { error in
                NSLog("coffee-bar: helper XPC: \(error)")
                failed = true
                done.signal()
            }
            guard let helper = proxy as? HelperProtocol else { return false }
            send(helper) { result in
                ok = result
                done.signal()
            }
            guard done.wait(timeout: .now() + 5) == .success else { return nil }
            if !failed || attempt == 2 { return ok }
        }
        return false
    }

    private func helperConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.helperRestarted() }
        }
        c.invalidationHandler = { [weak self, weak c] in
            DispatchQueue.main.async {
                if let self, self.connection === c { self.connection = nil }
            }
        }
        c.resume()
        connection = c
        return c
    }

    /// The helper process died (e.g. killed). launchd relaunches it on the next message; it starts
    /// with `disablesleep 0`, so re-apply if a session is active.
    private func helperRestarted() {
        guard sleepDisabled else { return }
        _ = callHelper({ $0.setSleepDisabled(true, reply: $1) })
    }
}
