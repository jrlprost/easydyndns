import XCTest
@testable import EasyDynDNSCore

final class PlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var config: Config = {
        var c = Config(zoneID: String(repeating: "a", count: 32), recordName: "home.example.com")
        c.retention = 12 * 3600
        c.refreshAfter = 15 * 60
        c.host = "test"
        return c
    }()

    func managed(_ ip: String, seenAgo: TimeInterval, id: String = UUID().uuidString) -> DNSRecord {
        DNSRecord(id: id, type: IPAddress.recordType(ip), name: "home.example.com", content: ip,
                  comment: Marker.comment(lastSeen: now.addingTimeInterval(-seenAgo), host: "test"))
    }

    func testCreatesMissingCurrentIP() {
        let plan = Planner.make(records: [], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertEqual(plan.create.map(\.ip), ["203.0.113.7"])
        XCTAssertEqual(plan.create.map(\.type), ["A"])
    }

    func testCreatesAAAAForIPv6() {
        let plan = Planner.make(records: [], current: ["203.0.113.7", "2001:db8::1"], now: now, config: config)
        XCTAssertEqual(plan.create.map(\.type), ["A", "AAAA"])
    }

    func testNeverReplacesAnotherIP() {
        let other = managed("198.51.100.1", seenAgo: 3600)
        let plan = Planner.make(records: [other], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertEqual(plan.create.map(\.ip), ["203.0.113.7"])
        XCTAssertTrue(plan.delete.isEmpty, "an IP seen 1h ago must stay published")
    }

    func testRefreshOnlyAfterThreshold() {
        let fresh = managed("203.0.113.7", seenAgo: 5 * 60)
        XCTAssertTrue(Planner.make(records: [fresh], current: ["203.0.113.7"], now: now, config: config).isEmpty)
        let stale = managed("203.0.113.7", seenAgo: 20 * 60)
        XCTAssertEqual(Planner.make(records: [stale], current: ["203.0.113.7"], now: now, config: config).refresh, [stale])
    }

    func testDeletesExpiredManagedRecord() {
        let expired = managed("198.51.100.1", seenAgo: 13 * 3600)
        let current = managed("203.0.113.7", seenAgo: 60)
        let plan = Planner.make(records: [expired, current], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertEqual(plan.delete.map(\.record), [expired])
    }

    func testNeverTouchesManualRecords() {
        let manual = DNSRecord(id: "m", type: "A", name: "home.example.com", content: "198.51.100.9", comment: "office VPN")
        let noComment = DNSRecord(id: "n", type: "A", name: "home.example.com", content: "198.51.100.10", comment: nil)
        let plan = Planner.make(records: [manual, noComment], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertTrue(plan.delete.isEmpty)
        XCTAssertTrue(plan.refresh.isEmpty)
    }

    func testManualRecordForCurrentIPIsLeftAlone() {
        let manual = DNSRecord(id: "m", type: "A", name: "home.example.com", content: "203.0.113.7", comment: "set by hand")
        let plan = Planner.make(records: [manual], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertTrue(plan.isEmpty)
    }

    func testUnreadableLastSeenIsKept() {
        let broken = DNSRecord(id: "b", type: "A", name: "home.example.com", content: "198.51.100.1", comment: "dyndns last-seen=garbage")
        let plan = Planner.make(records: [broken], current: ["203.0.113.7"], now: now, config: config)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testNeverDeletesLastRemainingRecord() {
        let a = managed("198.51.100.1", seenAgo: 20 * 3600)
        let b = managed("198.51.100.2", seenAgo: 30 * 3600)
        let plan = Planner.make(records: [a, b], current: [], now: now, config: config)
        XCTAssertEqual(plan.delete.map(\.record), [b], "the most recently seen record must survive")
    }

    func testIPv6ComparisonIsCanonical() {
        let record = managed("2001:db8::1", seenAgo: 60)
        let plan = Planner.make(records: [record], current: ["2001:0DB8:0:0::1"], now: now, config: config)
        XCTAssertTrue(plan.create.isEmpty)
        XCTAssertTrue(plan.delete.isEmpty)
    }

    func testMarker() {
        XCTAssertTrue(Marker.isManaged("dyndns last-seen=2026-01-01T00:00:00Z host=a"))
        XCTAssertFalse(Marker.isManaged("not dyndns"))
        XCTAssertFalse(Marker.isManaged("dyndnsx"))
        XCTAssertFalse(Marker.isManaged(nil))
        XCTAssertEqual(Marker.lastSeen("dyndns last-seen=2026-01-01T00:00:00Z host=a"), Date(timeIntervalSince1970: 1_767_225_600))
    }
}

final class ConfigTests: XCTestCase {
    func testParse() throws {
        let config = try Config.parse("""
        # comment
        zone_id = 0123456789abcdef0123456789abcdef
        record_name = Home.Example.com
        retention = 2m
        interval = 5m
        host = "My Laptop"
        """)
        XCTAssertEqual(config.recordName, "home.example.com")
        XCTAssertEqual(config.retention, 120)
        XCTAssertEqual(config.interval, 300)
        XCTAssertEqual(config.host, "My-Laptop")
    }

    func testTemplateIsRejectedUntilEdited() {
        XCTAssertThrowsError(try Config.parse(Config.template.replacingOccurrences(of: "home.example.com", with: "")))
    }

    func testRejectsBadDuration() {
        XCTAssertThrowsError(try Config.parse("zone_id = 0123456789abcdef0123456789abcdef\nrecord_name = a.b.c\nretention = 12"))
    }

    func testTracebodyParsing() {
        XCTAssertEqual(IPDetector.parse("fl=1\nh=1.1.1.1\nip=203.0.113.7\nts=1\n"), "203.0.113.7")
        XCTAssertEqual(IPDetector.parse("2001:db8::1\n"), "2001:db8::1")
        XCTAssertNil(IPAddress.normalize("2001:db8::1", family: AF_INET))
    }
}
