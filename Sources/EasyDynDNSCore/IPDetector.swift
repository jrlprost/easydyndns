import Foundation

public enum IPDetector {
    // Cloudflare's trace endpoint reached through IP literals, so each request is forced
    // onto one address family (api.cloudflare.com prefers IPv6 on dual-stack networks).
    static let v4Sources = ["https://1.1.1.1/cdn-cgi/trace", "https://api.ipify.org"]
    static let v6Sources = ["https://[2606:4700:4700::1111]/cdn-cgi/trace", "https://api6.ipify.org"]

    /// Returns the current public IPv4 and IPv6 (either may be nil).
    public static func detect(session: URLSession = .shared) async -> (v4: String?, v6: String?) {
        async let v4 = firstValid(v4Sources, family: AF_INET, session: session)
        async let v6 = firstValid(v6Sources, family: AF_INET6, session: session)
        return await (v4, v6)
    }

    static func firstValid(_ urls: [String], family: Int32, session: URLSession) async -> String? {
        for url in urls {
            if let ip = await fetch(url, session: session), let normalized = IPAddress.normalize(ip, family: family) {
                return normalized
            }
        }
        return nil
    }

    static func fetch(_ url: String, session: URLSession) async -> String? {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("EasyDynDNS", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else { return nil }
        return parse(body)
    }

    /// Accepts either a Cloudflare trace body (`ip=...` line) or a bare IP.
    static func parse(_ body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("\n") ? nil : trimmed
    }
}

public enum IPAddress {
    /// Canonical text form if `text` is a valid address of `family`, else nil.
    public static func normalize(_ text: String, family: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, text, &buffer) == 1 else { return nil }
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, buffer, &out, socklen_t(out.count)) != nil else { return nil }
        return String(cString: out)
    }

    /// Canonical form of an IPv4 or IPv6 address, or the input unchanged.
    public static func canonical(_ text: String) -> String {
        normalize(text, family: AF_INET) ?? normalize(text, family: AF_INET6) ?? text.lowercased()
    }

    public static func recordType(_ ip: String) -> String { ip.contains(":") ? "AAAA" : "A" }
}
