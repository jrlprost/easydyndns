import AppKit
import EasyDynDNSCore
import ServiceManagement

enum CLI {
    static let usage = """
    Usage: EasyDynDNS <command>

      install     Create the config if needed, store the API token, enable launch at login, start the app
      uninstall   Disable launch at login, quit the app, remove the token from the Keychain
      run         Run one synchronization now
      dry-run     Show what would be added, refreshed or deleted, without changing anything
      status      List published IPs with their last-seen and age
      set-token   Store (or replace) the Cloudflare API token in the Keychain

    Without a command, the menu bar app starts.
    Config: \(Config.fileURL.path)
    Log:    \(Log.fileURL.path)
    """

    static let commands: Set<String> = ["install", "uninstall", "run", "dry-run", "status", "set-token", "help", "--help", "-h"]

    static func isCommand(_ argument: String) -> Bool {
        commands.contains(argument) || !argument.hasPrefix("-")
    }

    static func main(_ arguments: [String]) async -> Int32 {
        switch arguments.first ?? "help" {
        case "run": return await run(dryRun: false)
        case "dry-run": return await run(dryRun: true)
        case "status": return await status()
        case "set-token": return await setToken()
        case "install": return await install()
        case "uninstall": return uninstall()
        case "help", "--help", "-h": print(usage); return 0
        default:
            fputs("Unknown command: \(arguments[0])\n\n\(usage)\n", stderr)
            return 2
        }
    }

    static func run(dryRun: Bool) async -> Int32 {
        if dryRun { print("DRY RUN: nothing will be written") }
        let result = await Engine.run(dryRun: dryRun) { print($0) }
        if let error = result.error { fputs("Error: \(error)\n", stderr); return 1 }
        if !dryRun {
            print("Added: \(list(result.added))  Refreshed: \(list(result.refreshed))  Deleted: \(list(result.deleted))")
        }
        return 0
    }

    static func list(_ items: [String]) -> String { items.isEmpty ? "-" : items.joined(separator: ", ") }

    static func status() async -> Int32 {
        do {
            let (name, lines) = try await Engine.status()
            print(name)
            if lines.isEmpty { print("  (no A/AAAA record)"); return 0 }
            let now = Date()
            print(pad("TYPE", 5) + pad("IP", 41) + pad("LAST SEEN (UTC)", 22) + pad("AGE", 8) + "HOST")
            for line in lines {
                let lastSeen = line.managed ? (line.lastSeen.map(Marker.timestamp) ?? "?") : "manual"
                let age = line.lastSeen.map { Format.age(now.timeIntervalSince($0)) } ?? "-"
                let host = (line.host ?? "-") + (line.current ? "  <- this network" : "")
                print(pad(line.type, 5) + pad(line.ip, 41) + pad(lastSeen, 22) + pad(age, 8) + host)
            }
            return 0
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func setToken() async -> Int32 {
        guard let token = readSecret("Cloudflare API token (input hidden): "), !token.isEmpty else {
            fputs("No token entered.\n", stderr); return 1
        }
        if let config = try? Config.load() {
            do { try await CloudflareClient(token: token, zoneID: config.zoneID).verify(name: config.recordName) } catch {
                fputs("Token rejected, not saved: \(error.localizedDescription)\n", stderr); return 1
            }
            print("Token verified against zone \(config.zoneID.prefix(6))…")
        }
        do { try Keychain.saveToken(token) } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
        print("Token stored in the macOS Keychain.")
        return 0
    }

    static func readSecret(_ prompt: String) -> String? {
        if isatty(STDIN_FILENO) == 0 { return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) }
        var buffer = [CChar](repeating: 0, count: 512)
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
        defer { buffer.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress, 0, $0.count) } }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var insideAppBundle: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func install() async -> Int32 {
        do {
            if try Config.writeTemplateIfMissing() {
                print("Created \(Config.fileURL.path). Fill in zone_id and record_name, then run install again.")
                return 1
            }
            let config = try Config.load()
            print("Config OK: \(config.recordName), retention \(Format.age(config.retention)), interval \(Format.age(config.interval))")
        } catch {
            fputs("Config error: \(error.localizedDescription)\nEdit \(Config.fileURL.path) and run install again.\n", stderr)
            return 1
        }

        if Keychain.readToken() == nil {
            let code = await setToken()
            if code != 0 { return code }
        } else {
            print("Token already in the Keychain (use set-token to replace it).")
        }

        guard insideAppBundle else {
            print("Not running from EasyDynDNS.app: skipping launch at login. Build the app with scripts/build.sh.")
            return 0
        }
        do {
            try SMAppService.mainApp.register()
            print("Launch at login enabled.")
        } catch {
            fputs("Could not enable launch at login: \(error.localizedDescription)\n", stderr)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = []
        _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        print("EasyDynDNS is running in the menu bar.")
        return 0
    }

    static func uninstall() -> Int32 {
        if insideAppBundle {
            try? SMAppService.mainApp.unregister()
            print("Launch at login disabled.")
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.processIdentifier != me {
                app.terminate()
            }
        }
        Keychain.deleteToken()
        print("""
        Token removed from the Keychain. DNS records were left as they are.
        Your config and logs are kept. To remove them too:
          rm -r "\(Config.directory.path)" "\(Log.directory.path)"
        """)
        return 0
    }
}
