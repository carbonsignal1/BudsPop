import AppKit
import Combine
import IOBluetooth
import ServiceManagement

@main
enum BudsPopMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let link = BudsLink()
    private var statusItem: NSStatusItem!
    private var popup: PopupController!
    private var observation: AnyCancellable?

    private var showOnConnect: Bool {
        get { UserDefaults.standard.bool(forKey: "showOnConnect") }
        set { UserDefaults.standard.set(newValue, forKey: "showOnConnect") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showOnConnect": true])
        Log.write("BudsPop started")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "Earbuds")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popup = PopupController(link: link)
        link.onAnnounce = { [weak self] in
            guard let self, self.showOnConnect else { return }
            self.popup.show(below: nil, autoHide: true)
        }
        observation = link.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatusItem() }
        }
        link.start()
        refreshStatusItem()

        // Opening the app by hand shows the card so it's obvious it's running; logging in doesn't.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
        if CommandLine.arguments.contains("--show") || !launchedAtLogin {
            popup.show(below: nil, autoHide: true)
        }
    }

    /// Opening the app again while it's running (Finder, Spotlight, `open`) brings the card back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if link.phase == .ready { link.refresh(full: false) }
        popup.show(below: nil, autoHide: true)
        return false
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let connected = link.phase != .disconnected
        button.appearsDisabled = !connected
        let levels = [link.left, link.right].compactMap { $0?.level }
        if connected, let lowest = levels.min() {
            button.title = " \(lowest)%"
        } else {
            button.title = ""
        }
        var tip = link.displayName
        if connected {
            if let l = link.left { tip += "\nLeft \(l.level)%" }
            if let r = link.right { tip += "\nRight \(r.level)%" }
            if let c = link.caseBattery { tip += "\nCase \(c.level)%" }
        } else {
            tip += " — not connected"
        }
        button.toolTip = tip
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popup.hide()
            statusItem.menu = buildMenu()
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            if !popup.isVisible, link.phase == .ready { link.refresh(full: false) }
            popup.toggle(below: sender)
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: link.displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if link.phase == .ready {
            for mode in NoiseMode.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(selectNoiseMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = link.noiseMode == mode ? .on : .off
                item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                if !link.canChangeNoiseMode { item.action = nil }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        if link.phase == .disconnected {
            let connect = NSMenuItem(title: "Connect", action: #selector(connect), keyEquivalent: "")
            connect.target = self
            connect.isEnabled = link.device != nil
            menu.addItem(connect)
        } else {
            let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
            disconnect.target = self
            menu.addItem(disconnect)
        }

        let deviceItem = NSMenuItem(title: "Earbuds", action: nil, keyEquivalent: "")
        let deviceMenu = NSMenu()
        let auto = NSMenuItem(title: "Automatic (OnePlus, OPPO, realme)", action: #selector(chooseDevice(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = link.preferredAddress == nil ? .on : .off
        deviceMenu.addItem(auto)
        deviceMenu.addItem(.separator())
        for device in BudsLink.pairedAudioDevices() {
            let item = NSMenuItem(title: device.name ?? device.addressString ?? "Unknown",
                                  action: #selector(chooseDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.addressString
            item.state = link.preferredAddress == device.addressString ? .on : .off
            deviceMenu.addItem(item)
        }
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        menu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show Pop-up When Earbuds Connect", action: #selector(toggleShowOnConnect), keyEquivalent: "")
        showItem.target = self
        showItem.state = showOnConnect ? .on : .off
        menu.addItem(showItem)

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let logItem = NSMenuItem(title: "Show Debug Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BudsPop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func selectNoiseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = NoiseMode(rawValue: raw) else { return }
        link.setNoiseMode(mode)
    }

    @objc private func connect() { link.connect() }
    @objc private func disconnect() { link.disconnect() }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        link.preferredAddress = sender.representedObject as? String
    }

    @objc private func toggleShowOnConnect() { showOnConnect.toggle() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item error: \(error)")
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }
}
