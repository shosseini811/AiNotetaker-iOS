import Foundation
import SwiftData

/// Uploads recordings to the server and keeps local copies of the results.
@MainActor
enum SyncManager {
    static func upload(_ recording: Recording, api: APIClient, context: ModelContext) async {
        recording.lastError = nil
        recording.serverStatus = "uploading"
        try? context.save()
        do {
            let server = try await api.uploadRecording(
                fileURL: recording.fileURL,
                title: recording.title,
                clientId: recording.id.uuidString,
                process: true
            )
            apply(server, to: recording)
            recording.uploadedAt = Date()
            try? context.save()
            await refreshUntilDone(recording, api: api, context: context)
        } catch {
            if APIClient.isConnectivityError(error), recording.serverId == nil {
                // A recording is never discarded just because the Mac cannot
                // be reached. RootView retries queued items after connectivity
                // returns and whenever the app becomes active.
                recording.serverStatus = "queued"
                recording.lastError = nil
            } else {
                if recording.serverId == nil { recording.serverStatus = nil }
                recording.lastError = error.localizedDescription
            }
            try? context.save()
        }
    }

    static func refresh(_ recording: Recording, api: APIClient, context: ModelContext) async {
        guard let serverId = recording.serverId else { return }
        do {
            let server = try await api.getRecording(serverId)
            apply(server, to: recording)
            try? context.save()
        } catch {
            recording.lastError = error.localizedDescription
            try? context.save()
        }
    }

    /// Polls every few seconds while the server is still processing.
    static func refreshUntilDone(_ recording: Recording, api: APIClient, context: ModelContext,
                                 maxSeconds: TimeInterval = 1800) async {
        let started = Date()
        while recording.serverStatus == "processing" {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            if Date().timeIntervalSince(started) > maxSeconds {
                recording.lastError = "The server is still processing. Refresh later to check again."
                try? context.save()
                return
            }
            await refresh(recording, api: api, context: context)
        }
    }

    static func apply(_ server: ServerRecording, to recording: Recording) {
        recording.serverId = server.id
        recording.serverStatus = server.status
        if let transcript = server.transcript, !transcript.isEmpty {
            recording.transcript = transcript
        }
        recording.transcriptionProvider = server.transcriptionProvider
        recording.transcriptionModel = server.transcriptionModel
        recording.transcriptCorrected = server.transcriptCorrected
        if let analysis = server.analysis {
            recording.analysis = analysis
        }
        if let noteId = server.noteId {
            recording.noteId = noteId
        }
        if let hasDenoised = server.hasDenoised {
            recording.hasDenoised = hasDenoised
        }
        if server.isDone, server.title != recording.title, recording.title.hasPrefix("Recording") {
            recording.title = server.title
        }
        recording.lastError = server.isError ? (server.error ?? "Processing failed") : nil
    }
}
