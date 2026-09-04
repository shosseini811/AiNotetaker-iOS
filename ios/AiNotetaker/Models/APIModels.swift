import Foundation

// Wire models for the AiNotetaker server API. JSON keys are snake_case on the
// server; the decoder converts them to these camelCase properties.

/// Where the Mac says it can be reached. Sent only to an authenticated client,
/// so the app can save the address that survives leaving the house without
/// anyone having to notice, or re-type, anything.
struct ServerEndpoints: Codable {
    var remoteUrl: String?
    var remoteSource: String?
    var directUrls: [String]?
    var reachableAnywhere: Bool?
    var setupHint: String?
}

struct ServerConfig: Codable {
    var appTitle: String
    var authRequired: Bool
    var authenticated: Bool
    var transcriptionConfigured: Bool
    var transcriptionProvider: String?
    var transcriptionModel: String?
    var analysisConfigured: Bool
    var denoiseEngine: String
    var language: String
    var version: String?
    var endpoints: ServerEndpoints?
}

struct Note: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var content: String?
    var snippet: String?
    var pinned: Bool
    var createdAt: String
    var updatedAt: String
}

struct Analysis: Codable, Hashable {
    var title: String?
    var summary: String?
    var keyPoints: [String]?
    var decisions: [String]?
    var actionItems: [String]?
    var people: [String]?
    var openQuestions: [String]?
    var topics: [String]?
    var language: String?
    var model: String?
}

struct ServerRecording: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var duration: Double?
    var size: Int?
    var status: String
    var error: String?
    var transcript: String?
    var transcriptionProvider: String?
    var transcriptionModel: String?
    var transcriptCorrected: Bool?
    var analysis: Analysis?
    var hasTranscript: Bool?
    var hasAnalysis: Bool?
    var hasDenoised: Bool?
    var denoiseEngine: String?
    var noteId: String?
    var createdAt: String
    var updatedAt: String

    var isProcessing: Bool { status == "processing" }
    var isDone: Bool { status == "done" }
    var isError: Bool { status == "error" }
}

struct ReportResponse: Codable {
    var report: String
    var itemCount: Int
    var note: Note?
}

struct OKResponse: Codable {
    var ok: Bool?
    var status: String?
}
