import AppKit
import EasyDynDNSCore
import Network
import ServiceManagement
import SwiftUI

struct EasyDynDNSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.icon)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)
        if let name = model.recordName { Text(name) }
        if !model.currentIPs.isEmpty { Text("IP: " + model.currentIPs.joined(separator: ", ")) }
        if let last = model.lastSuccess {
            Text("Last successful sync: " + last.formatted(date: .omitted, time: .shortened))
        }
        Divider()
        Button("Sync now") { model.trigger(force: true) }.disabled(!model.enabled || model.running)
        Toggle("Enabled", isOn: $model.enabled)
        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("Set Cloudflare token…") { model.promptToken() }
        Button("Open configuration") { model.openConfig() }
        Button("Open log") { NSWorkspace.shared.open(Log.fileURL) }
        Divider()
        Button("Quit EasyDynDNS") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            if enabled { trigger(force: true) }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var lastResult: RunResult?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var recordName: String?

    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var pending: Task<Void, Never>?
    private var lastRun: Date?
    private let monitor = NWPathMonitor()

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["enabled": true])
        enabled = defaults.bool(forKey: "enabled")
        lastSuccess = defaults.object(forKey: Engine.lastSuccessKey) as? Date
        recordName = (try? Config.load())?.recordName

        // Works automatically out of the box: register as login item on first launch only.
        if !defaults.bool(forKey: "loginItemConfigured") {
            defaults.set(true, forKey: "loginItemConfigured")
            setLaunchAtLogin(true)
        }

        Notifier.requestAuthorization()

        // Sync shortly after any network change (also fires once at startup).
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.trigger(after: 3) }
        }
        monitor.start(queue: DispatchQueue(label: "EasyDynDNS.network"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.trigger(after: 5) }
        }
        rescheduleTimer()
    }

    var currentIPs: [String] { lastResult?.currentIPs ?? [] }

    var healthy: Bool { enabled && lastResult?.succeeded == true }

    var statusText: String {
        if !enabled { return "Paused" }
        if running { return "Syncing…" }
        guard let result = lastResult else { return "Starting…" }
        if let error = result.error { return "Error: " + String(error.prefix(90)) }
        return "Active, IP published"
    }

    var icon: NSImage {
        let color: NSColor = healthy ? .systemGreen : .systemRed
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "network", accessibilityDescription: "EasyDynDNS")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    /// Schedules a sync, coalescing bursts of events (network flaps, wake, timer).
    /// Automatic triggers are ignored within 30 s of the previous sync; `force` bypasses that.
    func trigger(after delay: TimeInterval = 0, force: Bool = false) {
        guard enabled else { return }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < 30 { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        guard enabled, !running else { return }
        running = true
        let result = await Engine.run()
        running = false
        lastRun = Date()
        lastResult = result
        if result.succeeded { lastSuccess = Date() }
        recordName = (try? Config.load())?.recordName
        rescheduleTimer()
    }

    private func rescheduleTimer() {
        let wanted = (try? Config.load())?.interval ?? 300
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trigger() }
        }
        timer?.tolerance = min(30, wanted / 10)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("ERROR", "launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func promptToken() {
        let alert = NSAlert()
        alert.messageText = "Cloudflare API token"
        alert.informativeText = "Paste a token with the Zone > DNS > Edit permission, limited to your zone. It is stored only in your macOS Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try Keychain.saveToken(token)
            trigger(force: true)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    func openConfig() {
        _ = try? Config.writeTemplateIfMissing()
        let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let textEdit {
            NSWorkspace.shared.open([Config.fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Config.fileURL])
        }
    }
}
