import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Menu bar presence for the daemon: at-a-glance health (permissions, activity) and the
/// handful of actions a human at the Mac actually needs. Everything else stays CLI/MCP.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let version: String
    private let url: String
    private let launchdLabel = "dev.openab.mac-agent"
    private let logPath: String

    private var sessions = 0
    private var calls = 0
    private var denies = 0
    private var lastCall: (tool: String, who: String, at: Date)?
    private var flashWork: DispatchWorkItem?

    init(version: String, url: String, logPath: String) {
        self.version = version
        self.url = url
        self.logPath = logPath
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = Self.icon(active: false)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "oab-mc-agent \(version)"
        menu.delegate = self
        item.menu = menu
    }

    private static func icon(active: Bool) -> NSImage? {
        let name = active ? "desktopcomputer.and.arrow.down.fill" : "desktopcomputer.and.arrow.down"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: "oab-mc-agent")?.withSymbolConfiguration(cfg)
    }

    /// Fed every server log line; cheap string matching keeps the coupling to one closure.
    func observe(_ line: String) {
        if line.contains(" tools/call ") {
            calls += 1
            // "<principal> tools/call <tool>"
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "tools/call"), i + 1 < parts.count {
                lastCall = (String(parts[i + 1]), i > 0 ? String(parts[i - 1]) : "?", Date())
            }
            flash()
        } else if line.contains(" opened by ") {
            sessions += 1
        } else if line.hasPrefix("deny ") || line.contains(" deny ") {
            denies += 1
        }
    }

    private func flash() {
        item.button?.image = Self.icon(active: true)
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.item.button?.image = Self.icon(active: false) }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()

        menu.addItem(label("oab-mc-agent \(version)"))
        menu.addItem(label(url, action: #selector(copyURL), tip: "Click to copy"))
        menu.addItem(.separator())

        menu.addItem(label("\(screen ? "✓" : "✗") Screen Recording", action: screen ? nil : #selector(openScreenPane)))
        menu.addItem(label("\(ax ? "✓" : "✗") Accessibility", action: ax ? nil : #selector(openAXPane)))
        menu.addItem(.separator())

        menu.addItem(label("Sessions \(sessions) · Calls \(calls)" + (denies > 0 ? " · Denied \(denies)" : "")))
        if let l = lastCall {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            menu.addItem(label("Last: \(l.tool) by \(l.who) at \(f.string(from: l.at))"))
        } else {
            menu.addItem(label("No tool calls yet"))
        }
        menu.addItem(.separator())

        menu.addItem(label("Open Log", action: #selector(openLog)))
        menu.addItem(label("Restart Agent", action: #selector(restart)))
        menu.addItem(label("Quit Agent (stops launchd job)", action: #selector(quit)))
    }

    private func label(_ title: String, action: Selector? = nil, tip: String? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        m.isEnabled = action != nil
        m.toolTip = tip
        return m
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func openScreenPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func openAXPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
    @objc private func restart() {
        // KeepAlive brings us straight back; exiting is the restart.
        exit(0)
    }
    @objc private func quit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(launchdLabel)"]
        try? p.run()          // bootout SIGTERMs us; if it fails (not under launchd) just exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}
