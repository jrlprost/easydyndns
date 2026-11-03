import Foundation
import UserNotifications

/// Append-only log in ~/Library/Logs/EasyDynDNS/easydyndns.log (rotated at 1 MB).
/// Never pass secrets or HTTP headers to this logger.
public enum Log {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/EasyDynDNS", isDirectory: true)
    public static let fileURL = directory.appendingPathComponent("easydyndns.log")
    static let lock = NSLock()

    public static func write(_ level: String, _ message: String) {
        let line = "\(Marker.formatter.string(from: Date())) [\(level)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 1_000_000 {
            let old = directory.appendingPathComponent("easydyndns.log.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}

public enum Notifier {
    /// Notifications need a bundled app; silently skipped otherwise.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    public static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
