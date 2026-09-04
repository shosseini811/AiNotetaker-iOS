import Foundation

/// Where recordings live on disk.
enum RecordingStore {
    static var recordingsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func newFileURL() -> URL {
        recordingsDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    }

    static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
