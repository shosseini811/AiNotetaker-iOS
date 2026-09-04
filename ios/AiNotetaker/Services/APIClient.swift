import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case unauthorized
    case http(Int, String)
    case decoding(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set your server address in Settings first."
        case .invalidURL: return "The server address is not a valid URL."
        case .unauthorized: return "The server rejected the token. Check Settings."
        case .http(let code, let detail): return detail.isEmpty ? "Server error (HTTP \(code))." : detail
        case .decoding(let detail): return "Unexpected response from the server: \(detail)"
        case .unreachable: return "Couldn’t reach your Mac. The recording is safe on this iPhone and will upload automatically when the private connection returns."
        }
    }
}

/// Thin async client for the AiNotetaker server.
///
/// The address you type is only ever the *first* way in. The Mac reports the
/// addresses it answers on (see `app/network.py`), the app remembers them, and
/// every request goes to whichever one is reachable right now — so walking out
/// of the house switches the route instead of breaking the app.
@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    @Published var serverURL: String {
        didSet {
            guard serverURL != oldValue else { return }
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            forgetResolvedEndpoint()
        }
    }
    @Published var token: String {
        didSet {
            guard token != oldValue else { return }
            UserDefaults.standard.set(token, forKey: "apiToken")
            forgetResolvedEndpoint()
        }
    }

    /// Reported by the Mac: the address that also works on other Wi-Fi and cellular.
    @Published private(set) var learnedRemoteURL: String {
        didSet { UserDefaults.standard.set(learnedRemoteURL, forKey: Self.learnedRemoteKey) }
    }
    /// Reported by the Mac: addresses that reach it without a proxy — its
    /// tailnet IP and its LAN IP.
    @Published private(set) var learnedDirectURLs: [String] {
        didSet { UserDefaults.standard.set(learnedDirectURLs, forKey: Self.learnedDirectKey) }
    }
    /// What the Mac says to do when it has no address that works from anywhere.
    @Published private(set) var remoteAccessHint: String {
        didSet { UserDefaults.standard.set(remoteAccessHint, forKey: Self.hintKey) }
    }
    /// The address requests are currently going to, for the Settings screen.
    @Published private(set) var activeEndpoint: ServerEndpoint?

    private static let learnedRemoteKey = "learnedRemoteURL"
    private static let learnedDirectKey = "learnedDirectURLs"
    private static let hintKey = "remoteAccessHint"

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// The address elected for the network the phone is on right now. Cleared
    /// whenever that network changes, so it is never trusted across a move.
    private var resolvedURL: URL?
    private var resolveTask: Task<ServerEndpointProbe.Match, Error>?
    private var resolveTicket = 0
    private var pathObserver: NSObjectProtocol?

    private init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        token = UserDefaults.standard.string(forKey: "apiToken") ?? ""
        learnedRemoteURL = UserDefaults.standard.string(forKey: Self.learnedRemoteKey) ?? ""
        learnedDirectURLs = UserDefaults.standard.stringArray(forKey: Self.learnedDirectKey) ?? []
        remoteAccessHint = UserDefaults.standard.string(forKey: Self.hintKey) ?? ""
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        // Voice memories may be uploaded over cellular when the phone is away
        // from Wi-Fi. The original remains local until the request succeeds.
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        // Changing network means the route to the Mac may have changed too, so
        // the next request re-picks an address instead of trusting the old one.
        pathObserver = NotificationCenter.default.addObserver(
            forName: .networkPathChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forgetResolvedEndpoint() }
        }
    }

    // MARK: - Addresses

    /// Every address worth trying, most likely to keep working first.
    var candidates: [ServerEndpoint] {
        var seen = Set<String>()
        var found: [ServerEndpoint] = []

        func add(_ text: String, _ origin: ServerEndpoint.Origin) {
            guard let url = ServerAddress.url(from: text) else { return }
            guard seen.insert(url.absoluteString.lowercased()).inserted else { return }
            found.append(ServerEndpoint(url: url, origin: origin))
        }

        add(serverURL, .manual)
        add(learnedRemoteURL, .learnedRemote)
        for direct in learnedDirectURLs { add(direct, .learnedDirect) }

        // `sorted(by:)` is not stable, so rank ties fall back to discovery order.
        return found.enumerated()
            .sorted { ($0.element.preference, $0.offset) < ($1.element.preference, $1.offset) }
            .map(\.element)
    }

    var isConfigured: Bool { !candidates.isEmpty }

    /// True when at least one saved address survives leaving this Wi-Fi.
    var hasAddressThatWorksAnywhere: Bool { candidates.contains { $0.worksAwayFromWiFi } }

    var serverAddressKind: ServerAddressKind { ServerAddress.kind(ofText: serverURL) }

    func forgetResolvedEndpoint() {
        resolvedURL = nil
        resolveTask?.cancel()
        resolveTask = nil
    }

    /// Picks the reachable address for the current network, cached until the
    /// phone changes network or a request proves the choice is stale.
    func resolvedBaseURL(forceRefresh: Bool = false) async throws -> URL {
        if !forceRefresh, let resolved = resolvedURL { return resolved }
        if !forceRefresh, let inFlight = resolveTask {
            return try await inFlight.value.endpoint.url
        }
        resolveTask?.cancel()
        resolveTask = nil

        let options = candidates
        guard let first = options.first else { throw APIError.notConfigured }
        // A single saved address needs no election; a failed request still
        // surfaces the real network error.
        guard options.count > 1 else {
            adopt(first, cache: true)
            return first.url
        }

        let bearer = token
        resolveTicket &+= 1
        let ticket = resolveTicket
        let task = Task { try await ServerEndpointProbe.firstReachable(among: options, token: bearer) }
        resolveTask = task
        defer { if resolveTicket == ticket { resolveTask = nil } }
        do {
            let winner = try await task.value
            adopt(winner.endpoint, cache: true)
            // Learning a new address invalidates the election that produced it,
            // so the next request considers the address we just discovered.
            if let config = winner.config { learn(from: config) }
            return winner.endpoint.url
        } catch {
            // Nothing answered — most likely the phone is offline. Use the
            // preferred address so the caller surfaces a real network error,
            // and re-elect on the next attempt rather than caching a guess.
            adopt(first, cache: false)
            return first.url
        }
    }

    private func adopt(_ endpoint: ServerEndpoint, cache: Bool) {
        activeEndpoint = endpoint
        resolvedURL = cache ? endpoint.url : nil
    }

    /// Saves what the Mac reported about itself, so the app can reach it later
    /// without anyone re-typing an address.
    func learn(from config: ServerConfig) {
        guard let endpoints = config.endpoints else { return }
        let remote = (endpoints.remoteUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty, ServerAddress.url(from: remote) != nil, remote != learnedRemoteURL {
            learnedRemoteURL = remote
            forgetResolvedEndpoint()
        }
        let direct = (endpoints.directUrls ?? []).filter { ServerAddress.url(from: $0) != nil }
        if direct != learnedDirectURLs { learnedDirectURLs = direct }
        let hint = endpoints.setupHint ?? ""
        if hint != remoteAccessHint { remoteAccessHint = hint }
    }

    /// Asks the Mac where else it can be reached. Safe to call often.
    func refreshEndpoints() async {
        guard isConfigured else { return }
        _ = try? await fetchConfig()
    }

    // MARK: - Request plumbing

    private struct RequestSpec {
        let method: String
        let path: String
        var query: [URLQueryItem] = []
        var jsonBody: Data?
    }

    private func urlRequest(for spec: RequestSpec, base: URL) throws -> URLRequest {
        guard let url = ServerAddress.requestURL(base: base, path: spec.path, query: spec.query) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = spec.jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func jsonSpec<Body: Encodable>(_ method: String, _ path: String, body: Body) throws -> RequestSpec {
        RequestSpec(method: method, path: path, jsonBody: try encoder.encode(body))
    }

    private struct ErrorBody: Decodable { let detail: String? }

    private func handle<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw APIError.http(0, "No HTTP response") }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, detail)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Runs a request against the current address and, if the Mac turns out to
    /// be unreachable there, re-elects an address once and tries again. This is
    /// what makes walking out of the house a route change, not a failure.
    private func withEndpointFailover<T>(_ body: (URL) async throws -> T) async throws -> T {
        let base = try await resolvedBaseURL()
        do {
            return try await body(base)
        } catch {
            guard Self.isConnectivityError(error), candidates.count > 1 else {
                throw Self.normalizedConnectionError(error)
            }
            guard let retryBase = try? await resolvedBaseURL(forceRefresh: true), retryBase != base else {
                throw Self.normalizedConnectionError(error)
            }
            do {
                return try await body(retryBase)
            } catch {
                throw Self.normalizedConnectionError(error)
            }
        }
    }

    private func send<T: Decodable>(_ spec: RequestSpec) async throws -> T {
        try await withEndpointFailover { base -> T in
            let request = try self.urlRequest(for: spec, base: base)
            let (data, response) = try await self.session.data(for: request)
            return try self.handle(data: data, response: response)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(RequestSpec(method: "GET", path: path, query: query))
    }

    // MARK: - Config

    @discardableResult
    func fetchConfig() async throws -> ServerConfig {
        let config: ServerConfig = try await get("/api/config")
        learn(from: config)
        return config
    }

    // MARK: - Notes

    func listNotes(query: String = "") async throws -> [Note] {
        var items: [URLQueryItem] = []
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await get("/api/notes", query: items)
    }

    func getNote(_ id: String) async throws -> Note {
        try await get("/api/notes/\(id)")
    }

    func createNote(title: String, content: String) async throws -> Note {
        struct Body: Encodable { let title: String; let content: String }
        return try await send(try jsonSpec("POST", "/api/notes", body: Body(title: title, content: content)))
    }

    func updateNote(_ id: String, title: String? = nil, content: String? = nil, pinned: Bool? = nil) async throws -> Note {
        struct Body: Encodable { var title: String?; var content: String?; var pinned: Bool? }
        return try await send(try jsonSpec("PUT", "/api/notes/\(id)", body: Body(title: title, content: content, pinned: pinned)))
    }

    func deleteNote(_ id: String) async throws {
        let _: OKResponse = try await send(RequestSpec(method: "DELETE", path: "/api/notes/\(id)"))
    }

    // MARK: - Recordings

    func listRecordings() async throws -> [ServerRecording] {
        try await get("/api/recordings")
    }

    func getRecording(_ id: String) async throws -> ServerRecording {
        try await get("/api/recordings/\(id)")
    }

    /// Streams the audio file from disk as multipart (never loads it fully into memory).
    func uploadRecording(fileURL: URL, title: String, clientId: String,
                         process: Bool = true) async throws -> ServerRecording {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = try MultipartBody.write(
            boundary: boundary,
            fields: [
                ("title", title),
                ("process", process ? "1" : "0"),
                ("client_id", clientId),
            ],
            fileField: "audio",
            fileURL: fileURL,
            mimeType: Self.mimeType(for: fileURL)
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let spec = RequestSpec(method: "POST", path: "/api/recordings")
        return try await withEndpointFailover { base -> ServerRecording in
            var request = try self.urlRequest(for: spec, base: base)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await self.session.upload(for: request, fromFile: bodyURL)
            return try self.handle(data: data, response: response)
        }
    }

    func processRecording(_ id: String, denoise: Bool = true, transcribe: Bool = true, analyze: Bool = true) async throws {
        struct Body: Encodable { let denoise: Bool; let transcribe: Bool; let analyze: Bool }
        let _: OKResponse = try await send(try jsonSpec(
            "POST", "/api/recordings/\(id)/process",
            body: Body(denoise: denoise, transcribe: transcribe, analyze: analyze)
        ))
    }

    func analyzeRecording(_ id: String) async throws -> ServerRecording {
        try await send(RequestSpec(method: "POST", path: "/api/recordings/\(id)/analyze"))
    }

    func createNote(fromRecording id: String) async throws -> Note {
        try await send(RequestSpec(method: "POST", path: "/api/recordings/\(id)/note"))
    }

    func renameRecording(_ id: String, title: String) async throws -> ServerRecording {
        struct Body: Encodable { let title: String }
        return try await send(try jsonSpec("PUT", "/api/recordings/\(id)", body: Body(title: title)))
    }

    func updateTranscript(_ id: String, transcript: String,
                          refreshAnalysis: Bool = true) async throws -> ServerRecording {
        struct Body: Encodable {
            let transcript: String
            let refreshAnalysis: Bool
        }
        return try await send(try jsonSpec(
            "PUT", "/api/recordings/\(id)",
            body: Body(transcript: transcript, refreshAnalysis: refreshAnalysis)
        ))
    }

    func deleteRecording(_ id: String) async throws {
        let _: OKResponse = try await send(RequestSpec(method: "DELETE", path: "/api/recordings/\(id)"))
    }

    /// Downloads the original or noise-removed audio to a temporary file.
    func downloadAudio(_ id: String, variant: String) async throws -> URL {
        let spec = RequestSpec(method: "GET", path: "/api/recordings/\(id)/audio",
                               query: [URLQueryItem(name: "variant", value: variant)])
        let (tempURL, response) = try await withEndpointFailover { base -> (URL, URLResponse) in
            let request = try self.urlRequest(for: spec, base: base)
            return try await self.session.download(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw code == 401 ? APIError.unauthorized : APIError.http(code, "Could not download audio")
        }
        let ext = variant == "denoised" ? "flac" : "m4a"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(variant).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - Reports

    func generateReport(noteIds: [String] = [], recordingIds: [String] = [],
                        instructions: String = "", title: String = "",
                        saveAsNote: Bool = false) async throws -> ReportResponse {
        struct Body: Encodable {
            let noteIds: [String]
            let recordingIds: [String]
            let instructions: String
            let title: String
            let saveAsNote: Bool
        }
        return try await send(try jsonSpec("POST", "/api/reports", body: Body(
            noteIds: noteIds, recordingIds: recordingIds, instructions: instructions,
            title: title, saveAsNote: saveAsNote
        )))
    }

    // MARK: - Helpers

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }

    static func isConnectivityError(_ error: Error) -> Bool {
        if let apiError = error as? APIError, case .unreachable = apiError { return true }
        guard let urlError = error as? URLError else { return false }
        return connectivityCodes.contains(urlError.code)
    }

    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
        .dataNotAllowed, .secureConnectionFailed
    ]

    private static func normalizedConnectionError(_ error: Error) -> Error {
        isConnectivityError(error) ? APIError.unreachable : error
    }
}

extension Notification.Name {
    /// Posted by `ConnectivityMonitor` when the phone's route changes.
    static let networkPathChanged = Notification.Name("com.example.ainotetaker.networkPathChanged")
}

/// Builds a multipart/form-data body on disk so large recordings stream to the server.
enum MultipartBody {
    static func write(boundary: String, fields: [(String, String)], fileField: String,
                      fileURL: URL, mimeType: String) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }

        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; "
                  + "filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: \(mimeType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return output
    }
}
