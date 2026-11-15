import Foundation

// Root launchd daemon (registered by the app with SMAppService.daemon). It starts on demand when
// the app connects, and once at boot (RunAtLoad) to undo a `disablesleep 1` left behind by a crash.

/// Runs /usr/bin/pmset with fixed arguments, never through a shell. True on exit status 0.
@discardableResult
func pmset(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func restoreSleep() { pmset(["-a", "disablesleep", "0"]) }

final class Helper: NSObject, HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool) -> Void) {
        reply(pmset(["-a", "disablesleep", disabled ? "1" : "0"]))
    }

    func sleepNow(reply: @escaping (Bool) -> Void) {
        reply(pmset(["sleepnow"]))
    }
}

/// Tracks open connections on one serial queue. When the last one is lost (the app quit or
/// crashed), sleep is restored and the helper exits.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "com.coffeebar.helper.connections")
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = ObjectIdentifier(connection)
        let lost = { self.queue.async { self.remove(id) } }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = Helper()
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        queue.sync { connections[id] = connection }
        connection.resume()
        return true
    }

    /// Runs on `queue`. Both handlers may fire for one connection; only the first counts.
    private func remove(_ id: ObjectIdentifier) {
        guard connections.removeValue(forKey: id) != nil, connections.isEmpty else { return }
        restoreSleep()
        exit(0)
    }

    func exitIfNoConnection(after seconds: Double) {
        queue.asyncAfter(deadline: .now() + seconds) {
            if self.connections.isEmpty { exit(0) }
        }
    }
}

// Every launch starts from the safe state, including the boot-time RunAtLoad run.
restoreSleep()

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
// Only the CoffeeBar app signed by our team may connect (macOS 13+).
listener.setConnectionCodeSigningRequirement(
    "anchor apple generic and identifier \"\(appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
)
listener.delegate = delegate
listener.resume()
delegate.exitIfNoConnection(after: 10)
dispatchMain()
