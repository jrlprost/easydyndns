import Foundation
import SystemConfiguration

public struct AppError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Config {
    public var zoneID: String
    public var recordName: String
    public var retention: TimeInterval = 12 * 3600
    public var interval: TimeInterval = 5 * 60
    public var refreshAfter: TimeInterval = 15 * 60
    public var ttl: Int = 60
    public var host: String = Config.defaultHost()

    public init(zoneID: String, recordName: String) {
        self.zoneID = zoneID
        self.recordName = recordName
    }

    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/easydyndns", isDirectory: true)
    public static let fileURL = directory.appendingPathComponent("config")

    public static func load(from url: URL = fileURL) throws -> Config {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AppError("Config not found at \(url.path). Run `EasyDynDNS install` or copy config.example there.")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> Config {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { throw AppError("Invalid config line: \(line)") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }

        guard let zone = values["zone_id"], zone.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw AppError("zone_id is missing or invalid (expected the 32-character Zone ID from the Cloudflare dashboard).")
        }
        guard let name = values["record_name"]?.lowercased(), name.contains("."), !name.contains(" ") else {
            throw AppError("record_name is missing or invalid (e.g. home.example.com).")
        }
        var config = Config(zoneID: zone, recordName: name)
        if let v = values["retention"] { config.retention = try duration(v, key: "retention") }
        if let v = values["interval"] { config.interval = try duration(v, key: "interval") }
        if let v = values["refresh_after"] { config.refreshAfter = try duration(v, key: "refresh_after") }
        if let v = values["ttl"] {
            guard let ttl = Int(v), ttl == 1 || (60...86400).contains(ttl) else { throw AppError("ttl must be 1 (auto) or 60-86400.") }
            config.ttl = ttl
        }
        if let v = values["host"], !v.isEmpty { config.host = sanitizeHost(v) }
        guard config.retention >= 60, config.interval >= 60 else { throw AppError("retention and interval must be at least 1m.") }
        return config
    }

    /// Parses "30s", "5m", "12h", "1d".
    static func duration(_ text: String, key: String) throws -> TimeInterval {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let unit = text.last.flatMap({ units[$0] }), let n = Double(text.dropLast()), n > 0 else {
            throw AppError("\(key) must look like 30s, 5m, 12h or 1d (got \"\(text)\").")
        }
        return n * unit
    }

    static func sanitizeHost(_ text: String) -> String {
        let cleaned = String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }.prefix(32))
        return cleaned.isEmpty ? "mac" : cleaned
    }

    public static func defaultHost() -> String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac"
        return sanitizeHost(name)
    }

    /// Writes a starter config if none exists. Returns true if a file was created.
    @discardableResult
    public static func writeTemplateIfMissing() throws -> Bool {
        if FileManager.default.fileExists(atPath: fileURL.path) { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try template.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return true
    }

    public static let template = """
    # EasyDynDNS configuration
    # Zone ID: Cloudflare dashboard > your domain > Overview > API section (right column)
    zone_id = 00000000000000000000000000000000
    # DNS name that will hold one A/AAAA record per active public IP
    record_name = home.example.com
    # Delete an IP after this long without any sign of life (s, m, h, d)
    retention = 12h
    # How often to check (the app also checks immediately on network change)
    interval = 5m
    # Only rewrite the last-seen comment when it is older than this
    refresh_after = 15m
    # TTL of created records in seconds (60 minimum, 1 = auto)
    ttl = 60
    # Label stored in the record comment (defaults to this Mac's local host name)
    # host = my-laptop

    """
}
