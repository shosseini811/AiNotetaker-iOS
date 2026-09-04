import Foundation
import SwiftData

/// A recording stored on this device (the lossless original), plus whatever the
/// server has produced for it (transcript, analysis). The audio file itself lives
/// in Documents/Recordings/ so it survives app updates and is backed up.
@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var fileName: String
    var fileSize: Int

    var serverId: String?
    var serverStatus: String?   // uploading | uploaded | processing | done | error
    var transcript: String?
    var transcriptionProvider: String?
    var transcriptionModel: String?
    var transcriptCorrected: Bool?
    var analysisData: Data?
    var noteId: String?
    var hasDenoised: Bool?
    var uploadedAt: Date?
    var lastError: String?

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(),
         duration: Double, fileName: String, fileSize: Int) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.fileSize = fileSize
    }

    var fileURL: URL { RecordingStore.recordingsDirectory.appendingPathComponent(fileName) }

    var analysis: Analysis? {
        get { analysisData.flatMap { try? JSONDecoder().decode(Analysis.self, from: $0) } }
        set { analysisData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}
