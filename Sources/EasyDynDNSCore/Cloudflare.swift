import Foundation

public struct DNSRecord: Codable, Equatable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
    public let comment: String?

    public init(id: String, type: String, name: String, content: String, comment: String?) {
        self.id = id; self.type = type; self.name = name; self.content = content; self.comment = comment
    }
}

/// Minimal Cloudflare DNS client. Needs only a token with Zone > DNS > Edit on one zone.
/// Request headers are never logged or included in errors.
public final class CloudflareClient {
    let token: String
    let zoneID: String
    let session: URLSession
    let base = URL(string: "https://api.cloudflare.com/client/v4/")!

    public init(token: String, zoneID: String, session: URLSession = .shared) {
        self.token = token; self.zoneID = zoneID; self.session = session
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Message: Decodable { let code: Int; let message: String }
        let success: Bool
        let errors: [Message]?
        let result: T?
    }
    struct Empty: Decodable {}

    /// All A and AAAA records with exactly this name.
    public func listRecords(name: String) async throws -> [DNSRecord] {
        var components = URLComponents(url: base.appendingPathComponent("zones/\(zoneID)/dns_records"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "per_page", value: "100")]
        let records: [DNSRecord] = try await send("GET", url: components.url!)
        return records.filter { $0.type == "A" || $0.type == "AAAA" }
    }

    public func createRecord(type: String, name: String, content: String, ttl: Int, comment: String) async throws -> DNSRecord {
        let body: [String: Any] = ["type": type, "name": name, "content": content, "ttl": ttl, "proxied": false, "comment": comment]
        return try await send("POST", url: base.appendingPathComponent("zones/\(zoneID)/dns_records"), body: body)
    }

    public func updateComment(id: String, comment: String) async throws {
        let _: DNSRecord = try await send("PATCH", url: base.appendingPathComponent("zones/\(zoneID)/dns_records/\(id)"), body: ["comment": comment])
    }

    public func deleteRecord(id: String) async throws {
        let _: Empty = try await send("DELETE", url: base.appendingPathComponent("zones/\(zoneID)/dns_records/\(id)"))
    }

    /// Checks that the token is valid and can read this zone's DNS records.
    public func verify(name: String) async throws {
        _ = try await listRecords(name: name)
    }

    private func send<T: Decodable>(_ method: String, url: URL, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw AppError("Cloudflare API unreachable: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw AppError("Cloudflare API returned an unexpected response (HTTP \(status)).")
        }
        guard envelope.success, let result = envelope.result else {
            let detail = envelope.errors?.map { "\($0.message) [\($0.code)]" }.joined(separator: "; ") ?? "unknown error"
            throw AppError("Cloudflare API error (HTTP \(status)): \(detail)")
        }
        return result
    }
}
