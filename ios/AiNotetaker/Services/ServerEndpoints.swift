import Foundation

/// How a saved server address behaves once the iPhone leaves the house.
enum ServerAddressKind: Equatable {
    case unset
    case invalid
    case localOnly
    case tailscale
    case secureRemote
    case insecureRemote

    /// True when the address keeps resolving on other Wi-Fi and on cellular.
    var worksAwayFromWiFi: Bool {
        self == .tailscale || self == .secureRemote
    }
}

/// Parsing and classification of the addresses that point at your Mac.
enum ServerAddress {
    /// Normalizes what someone typed (or what the Mac reported) into a URL.
    static func url(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        // A bare *.ts.net name is Tailscale Serve, which always answers HTTPS
        // on 443 with a real certificate. The same name *with a port* is the
        // app's own port straight over the tailnet, which speaks plain HTTP
        // inside the tunnel — upgrading that one would break it.
        let servesHTTPS = isTailscaleHostname(value) && !hasExplicitPort(value)
        if !hasScheme {
            value = (servesHTTPS ? "https://" : "http://") + value
        } else if lower.hasPrefix("http://") && servesHTTPS {
            value = "https://" + String(value.dropFirst("http://".count))
        }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The `host[:port]` part of an address, with or without a scheme or path.
    private static func authority(_ value: String) -> String {
        var rest = value
        if let separator = rest.range(of: "://") { rest = String(rest[separator.upperBound...]) }
        return rest.split(separator: "/").first.map(String.init) ?? rest
    }

    static func hasExplicitPort(_ value: String) -> Bool {
        let hostPort = authority(value)
        guard let colon = hostPort.lastIndex(of: ":") else { return false }
        let port = hostPort[hostPort.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }

    static func kind(of url: URL) -> ServerAddressKind {
        guard let host = url.host?.lowercased() else { return .invalid }
        if isTailscaleHostname(host) || isTailscaleIP(host) { return .tailscale }
        if isLocalHost(host) { return .localOnly }
        return url.scheme?.lowercased() == "https" ? .secureRemote : .insecureRemote
    }

    static func kind(ofText text: String) -> ServerAddressKind {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unset }
        guard let url = url(from: text) else { return .invalid }
        return kind(of: url)
    }

    static func isTailscaleHostname(_ value: String) -> Bool {
        let host = authority(value.lowercased())
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name.hasSuffix(".ts.net")
    }

    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return values
    }

    static func isTailscaleIP(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 127
            || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
}

/// One address worth trying when the app looks for your Mac. The app keeps the
/// address you typed *and* the ones the Mac reported about itself, so leaving
/// home switches route instead of breaking the connection.
struct ServerEndpoint: Hashable, Sendable {
    enum Origin: String, Sendable {
        case manual         // typed in Settings
        case learnedRemote  // reported by the Mac: its address behind the proxy
        case learnedDirect  // reported by the Mac: its tailnet and LAN addresses
    }

    let url: URL
    let origin: Origin

    var kind: ServerAddressKind { ServerAddress.kind(of: url) }
    var worksAwayFromWiFi: Bool { kind.worksAwayFromWiFi }

    /// Lower sorts first. An address that survives leaving the house always
    /// beats one that only exists on the network the phone happens to be on.
    var preference: Int {
        switch (worksAwayFromWiFi, origin) {
        case (true, .manual): return 0
        case (true, _): return 1
        case (false, .manual): return 2
        case (false, _): return 3
        }
    }

    var displayName: String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port, !(url.scheme == "https" && port == 443), !(url.scheme == "http" && port == 80) {
            return "\(host):\(port)"
        }
        return host
    }
}

extension ServerAddress {
    /// Builds a request URL against a base address, keeping any path prefix
    /// (so a server behind `https://host/ainotetaker` still works).
    static func requestURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
}

/// Finds which saved address answers right now.
///
/// Every candidate is asked at the same time and the most preferred one that
/// replies wins, so switching from home Wi-Fi to cellular costs one short
/// round trip rather than a failed upload.
enum ServerEndpointProbe {
    struct Match: Sendable {
        let rank: Int
        let endpoint: ServerEndpoint
        let config: ServerConfig?
    }

    /// Deliberately short: an address that is not answering should lose the
    /// race quickly, not hold up the request behind it.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    /// `options` must already be ordered best-first; index 0 wins immediately.
    static func firstReachable(among options: [ServerEndpoint], token: String) async throws -> Match {
        try await withThrowingTaskGroup(of: Match?.self) { group in
            for (rank, endpoint) in options.enumerated() {
                group.addTask { await probe(endpoint, rank: rank, token: token) }
            }
            var best: Match?
            for try await found in group {
                guard let found else { continue }
                if best == nil || found.rank < best!.rank { best = found }
                if best?.rank == 0 {
                    group.cancelAll()  // the preferred address answered
                    break
                }
            }
            guard let best else { throw APIError.unreachable }
            return best
        }
    }

    private static func probe(_ endpoint: ServerEndpoint, rank: Int, token: String) async -> Match? {
        guard let url = ServerAddress.requestURL(base: endpoint.url, path: "/api/config") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        // 401 still proves this address reaches the server; only the token is wrong.
        if http.statusCode == 401 { return Match(rank: rank, endpoint: endpoint, config: nil) }
        guard http.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let config = try? decoder.decode(ServerConfig.self, from: data) else { return nil }
        return Match(rank: rank, endpoint: endpoint, config: config)
    }
}
