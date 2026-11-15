import AppKit

/// The menu-bar icon and its menu (Menu F in files/README.md). Presentation only:
/// every click goes to `onAction`, and `update` redraws everything.
@MainActor
final class TrayMenu: NSObject, NSMenuDelegate {
    enum Action { case preset(Int), custom, enableLidMode, heatFuse, startAtLogin, exit }

    var onAction: (Action) -> Void = { _ in }
    var onWillOpen: () -> Void = {}

    private let statusItem: NSStatusItem
    private let idleImage: NSImage?
    private let activeImage: NSImage?
    private let countdown = NSMenuItem()
    private let keepAwake = NSMenuItem()
    private var presets: [NSMenuItem] = []
    private let custom = NSMenuItem()
    private let lidMode = NSMenuItem()
    private let heatFuse = NSMenuItem()
    private let startAtLogin = NSMenuItem()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Template images (set in the asset catalog), so macOS tints them for the menu bar.
        idleImage = NSImage(named: "MenuIdle")
        activeImage = NSImage(named: "MenuActive")
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        setUp(countdown, symbol: "timer")
        countdown.isEnabled = false
        menu.addItem(countdown)
        menu.addItem(.separator())

        let durations = NSMenu()
        durations.autoenablesItems = false
        for (i, preset) in Session.presets.enumerated() {
            let item = NSMenuItem()
            setUp(item, title: preset.label, action: #selector(presetClicked(_:)))
            item.tag = i
            durations.addItem(item)
            presets.append(item)
        }
        durations.addItem(.separator())
        setUp(custom, symbol: "slider.horizontal.3", action: #selector(customClicked))
        durations.addItem(custom)
        setUp(keepAwake, title: "Keep awake", symbol: "cup.and.saucer")
        keepAwake.submenu = durations
        menu.addItem(keepAwake)

        setUp(lidMode, title: "Enable closed-lid mode…", symbol: "laptopcomputer", action: #selector(lidModeClicked))
        lidMode.isHidden = true
        menu.addItem(lidMode)
        menu.addItem(.separator())

        setUp(heatFuse, title: "Heat fuse", symbol: "thermometer.medium", action: #selector(heatFuseClicked))
        menu.addItem(heatFuse)
        setUp(startAtLogin, title: "Start at login", symbol: "power", action: #selector(startAtLoginClicked))
        menu.addItem(startAtLogin)
        menu.addItem(.separator())

        let exit = NSMenuItem()
        setUp(exit, title: "Exit", symbol: "rectangle.portrait.and.arrow.right", action: #selector(exitClicked))
        exit.keyEquivalent = "q" // ⌘Q: command is the default modifier
        menu.addItem(exit)

        statusItem.menu = menu
        statusItem.button?.image = idleImage
    }

    /// `remaining` is nil while idle; `status` (last error or heat-fuse trip) is shown only then.
    func update(choice: Session.Choice?, remaining: TimeInterval?, status: String?,
                heatFuse fuseOn: Bool, temperature: String?, startAtLogin loginOn: Bool,
                needsApproval: Bool) {
        if let remaining {
            countdown.title = "Awake · \(DurationParser.hms(remaining)) left"
        } else {
            countdown.title = status ?? "Not keeping awake"
        }

        keepAwake.title = choice.map { "Keep awake · \($0.label)" } ?? "Keep awake"
        for (i, item) in presets.enumerated() {
            item.state = choice == .preset(i) ? .on : .off
        }
        if let choice, case .custom = choice {
            custom.title = "Custom (\(choice.label))"
            custom.state = .on
        } else {
            custom.title = "Custom…"
            custom.state = .off
        }

        lidMode.isHidden = !needsApproval
        heatFuse.title = temperature.map { "Heat fuse · \($0)" } ?? "Heat fuse"
        heatFuse.state = fuseOn ? .on : .off
        startAtLogin.state = loginOn ? .on : .off

        let image = choice == nil ? idleImage : activeImage
        if statusItem.button?.image !== image {
            statusItem.button?.image = image
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        onWillOpen()
    }

    @objc private func presetClicked(_ sender: NSMenuItem) { onAction(.preset(sender.tag)) }
    @objc private func customClicked() { onAction(.custom) }
    @objc private func lidModeClicked() { onAction(.enableLidMode) }
    @objc private func heatFuseClicked() { onAction(.heatFuse) }
    @objc private func startAtLoginClicked() { onAction(.startAtLogin) }
    @objc private func exitClicked() { onAction(.exit) }

    private func setUp(_ item: NSMenuItem, title: String = "", symbol: String? = nil, action: Selector? = nil) {
        item.title = title
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        item.action = action
        item.target = self
    }
}
