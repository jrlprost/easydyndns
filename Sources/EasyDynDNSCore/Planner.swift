import Foundation

/// Record comment format: "dyndns last-seen=2026-01-01T12:00:00Z host=my-laptop".
/// Records without the leading "dyndns" marker are never modified or deleted.
public enum Marker {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func timestamp(_ date: Date) -> String { formatter.string(from: date) }

    public static func comment(lastSeen: Date, host: String) -> String {
        "dyndns last-seen=\(timestamp(lastSeen)) host=\(host)"
    }

    public static func isManaged(_ comment: String?) -> Bool {
        comment?.split(separator: " ").first == "dyndns"
    }

    public static func fields(_ comment: String?) -> [String: String] {
        guard isManaged(comment), let comment else { return [:] }
        var out: [String: String] = [:]
        for part in comment.split(separator: " ").dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    public static func lastSeen(_ comment: String?) -> Date? {
        fields(comment)["last-seen"].flatMap { formatter.date(from: $0) }
    }
}

public struct Plan {
    public var create: [(type: String, ip: String)] = []
    public var refresh: [DNSRecord] = []
    public var delete: [(record: DNSRecord, age: TimeInterval)] = []
    public var notes: [String] = []

    public var isEmpty: Bool { create.isEmpty && refresh.isEmpty && delete.isEmpty }
}

public enum Planner {
    /// Pure decision logic: what to create, refresh and delete for this run.
    /// `current` must be non-empty; the caller aborts earlier when no IP could be determined.
    public static func make(records: [DNSRecord], current: [String], now: Date, config: Config) -> Plan {
        var plan = Plan()
        let currentSet = Set(current.map(IPAddress.canonical))

        for ip in current {
            let type = IPAddress.recordType(ip)
            let matches = records.filter { $0.type == type && IPAddress.canonical($0.content) == IPAddress.canonical(ip) }
            if matches.isEmpty {
                plan.create.append((type, ip))
            } else if let managed = matches.first(where: { Marker.isManaged($0.comment) }) {
                if let seen = Marker.lastSeen(managed.comment), now.timeIntervalSince(seen) < config.refreshAfter {
                    plan.notes.append("\(ip) is published, last-seen is recent")
                } else {
                    plan.refresh.append(managed)
                }
            } else {
                plan.notes.append("\(ip) is covered by a manual record (left untouched)")
            }
        }

        for record in records where Marker.isManaged(record.comment) && !currentSet.contains(IPAddress.canonical(record.content)) {
            guard let seen = Marker.lastSeen(record.comment) else {
                plan.notes.append("\(record.content) has an unreadable last-seen, kept")
                continue
            }
            let age = now.timeIntervalSince(seen)
            if age > config.retention { plan.delete.append((record, age)) }
        }

        // Safety net: never delete the last remaining record of the name.
        if records.count + plan.create.count - plan.delete.count < 1, !plan.delete.isEmpty {
            plan.delete.sort { $0.age < $1.age }
            let kept = plan.delete.removeFirst()
            plan.notes.append("\(kept.record.content) kept: it is the last remaining record")
        }
        return plan
    }
}
