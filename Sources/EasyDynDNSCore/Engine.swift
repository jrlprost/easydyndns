import Foundation

public struct RunResult {
    public var currentIPs: [String] = []
    public var added: [String] = []
    public var refreshed: [String] = []
    public var deleted: [String] = []
    public var error: String?
    public var succeeded: Bool { error == nil }
}

/// One synchronization pass. Shared by the menu bar app and the CLI.
public enum Engine {
    static let failureThreshold = 3
    static let failuresKey = "consecutiveFailures"
    public static let lastSuccessKey = "lastSuccess"

    /// - Parameter dryRun: compute and print the plan, write nothing (no DNS change, no log, no counters).
    public static func run(dryRun: Bool = false, print output: (String) -> Void = { _ in }) async -> RunResult {
        var result = RunResult()
        do {
            let config = try Config.load()
            guard let token = Keychain.readToken() else {
                throw AppError("No Cloudflare API token in the Keychain. Use \"Set Cloudflare token…\" in the menu or `EasyDynDNS set-token`.")
            }
            let ips = await IPDetector.detect()
            result.currentIPs = [ips.v4, ips.v6].compactMap { $0 }
            guard !result.currentIPs.isEmpty else {
                throw AppError("Offline: could not determine the public IP. Nothing changed, nothing deleted.")
            }
            output("Public IP(s): \(result.currentIPs.joined(separator: ", "))")

            let client = CloudflareClient(token: token, zoneID: config.zoneID)
            let records = try await client.listRecords(name: config.recordName)
            let now = Date()
            let plan = Planner.make(records: records, current: result.currentIPs, now: now, config: config)
            let comment = Marker.comment(lastSeen: now, host: config.host)

            if dryRun {
                output("Records for \(config.recordName): \(records.count)")
                plan.create.forEach { output("  would ADD      \($0.type) \($0.ip)") }
                plan.refresh.forEach { output("  would REFRESH  \($0.type) \($0.content)") }
                plan.delete.forEach { output("  would DELETE   \($0.record.type) \($0.record.content) (last seen \(Format.age($0.age)) ago)") }
                plan.notes.forEach { output("  note: \($0)") }
                if plan.isEmpty { output("  nothing to do") }
                return result
            }

            for item in plan.create {
                _ = try await client.createRecord(type: item.type, name: config.recordName, content: item.ip, ttl: config.ttl, comment: comment)
                result.added.append(item.ip)
                Log.write("ADD", "\(item.type) \(config.recordName) -> \(item.ip)")
            }
            for record in plan.refresh {
                try await client.updateComment(id: record.id, comment: comment)
                result.refreshed.append(record.content)
                Log.write("REFRESH", "\(record.type) \(record.content) last-seen updated")
            }
            for item in plan.delete {
                try await client.deleteRecord(id: item.record.id)
                result.deleted.append(item.record.content)
                Log.write("DELETE", "\(item.record.type) \(item.record.content) (no sign of life for \(Format.age(item.age)))")
            }
            Log.write("OK", "sync done for \(config.recordName): current \(result.currentIPs.joined(separator: ", ")), "
                      + "\(records.count + result.added.count - result.deleted.count) record(s) published")
        } catch {
            result.error = error.localizedDescription
        }
        if !dryRun { record(result) }
        return result
    }

    static func record(_ result: RunResult) {
        let defaults = UserDefaults.standard
        if let error = result.error {
            Log.write("ERROR", error)
            let failures = defaults.integer(forKey: failuresKey) + 1
            defaults.set(failures, forKey: failuresKey)
            if failures == failureThreshold {
                Notifier.post("EasyDynDNS: sync failing", "\(failures) failures in a row. \(error)")
            }
            return
        }
        defaults.set(0, forKey: failuresKey)
        defaults.set(Date(), forKey: lastSuccessKey)
        if !result.added.isEmpty {
            Notifier.post("EasyDynDNS: IP added", result.added.joined(separator: ", "))
        }
        if !result.deleted.isEmpty {
            Notifier.post("EasyDynDNS: IP removed", result.deleted.joined(separator: ", "))
        }
    }

    public struct StatusLine {
        public let type: String
        public let ip: String
        public let lastSeen: Date?
        public let host: String?
        public let managed: Bool
        public let current: Bool
    }

    /// Records currently published for the configured name.
    public static func status() async throws -> (name: String, lines: [StatusLine]) {
        let config = try Config.load()
        guard let token = Keychain.readToken() else { throw AppError("No Cloudflare API token in the Keychain.") }
        async let ipsTask = IPDetector.detect()
        let records = try await CloudflareClient(token: token, zoneID: config.zoneID).listRecords(name: config.recordName)
        let ips = await ipsTask
        let current = Set([ips.v4, ips.v6].compactMap { $0 })
        let lines = records.map { r in
            StatusLine(type: r.type, ip: r.content, lastSeen: Marker.lastSeen(r.comment), host: Marker.fields(r.comment)["host"],
                       managed: Marker.isManaged(r.comment), current: current.contains(IPAddress.canonical(r.content)))
        }
        return (config.recordName, lines.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) })
    }
}

public enum Format {
    public static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))" }
        return "\(s / 86400)d\(s % 86400 / 3600)h"
    }
}
