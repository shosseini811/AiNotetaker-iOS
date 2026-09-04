import SwiftUI
import SwiftData

@main
struct AiNotetakerApp: App {
    @StateObject private var api = APIClient.shared
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var connectivity = ConnectivityMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(api)
                .environmentObject(recorder)
                .environmentObject(connectivity)
        }
        .modelContainer(for: Recording.self)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @AppStorage("autoUpload") private var autoUpload = true
    @Query(sort: \Recording.createdAt, order: .forward) private var recordings: [Recording]
    @State private var syncingPending = false

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "mic.fill") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "waveform") }
            NotesView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(AppTheme.accent)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            recoverInterruptedUploads()
            // Ask the Mac where else it answers before the first upload, so a
            // phone that left the house already knows the way back in.
            await api.refreshEndpoints()
            await syncPendingRecordings()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                if scenePhase == .active {
                    await syncPendingRecordings()
                }
            }
        }
        .onChange(of: connectivity.isOnline) { _, isOnline in
            guard isOnline else { return }
            Task {
                await api.refreshEndpoints()
                await syncPendingRecordings()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await api.refreshEndpoints()
                await syncPendingRecordings()
            }
        }
    }

    private func recoverInterruptedUploads() {
        var changed = false
        for recording in recordings
        where recording.serverId == nil && recording.serverStatus == "uploading" {
            recording.serverStatus = "queued"
            recording.lastError = nil
            changed = true
        }
        if changed { try? context.save() }
    }

    private func syncPendingRecordings() async {
        guard !syncingPending, autoUpload, api.isConfigured, connectivity.isOnline else { return }
        syncingPending = true
        defer { syncingPending = false }

        // Upload one at a time to keep memory and cellular usage predictable.
        for recording in recordings
        where recording.serverId == nil && recording.serverStatus == "queued" {
            guard !Task.isCancelled else { return }
            await SyncManager.upload(recording, api: api, context: context)
            if recording.serverStatus == "queued" { return }
        }

        // Resume status updates after the app was suspended during server work.
        for recording in recordings
        where recording.serverId != nil && recording.serverStatus == "processing" {
            guard !Task.isCancelled else { return }
            await SyncManager.refresh(recording, api: api, context: context)
        }
    }
}
