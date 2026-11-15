import Foundation

/// XPC interface of the root helper. Deliberately tiny: nothing else is exposed to a root process.
@objc protocol HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Bool) -> Void)
    func sleepNow(reply: @escaping (Bool) -> Void)
}

let helperMachServiceName = "com.coffeebar.helper"
let helperPlistName = "com.coffeebar.helper.plist"
let appBundleID = "com.coffeebar.app"

/// SET THIS to your Apple Developer team ID (10 characters, e.g. "AB12CD34EF"; Xcode → Signing,
/// or `codesign -dv --verbose=4 CoffeeBar.app` → TeamIdentifier). The helper only accepts XPC
/// connections from an app signed with this team ID and the bundle ID above.
let teamID = "6BAE823PNZ"
