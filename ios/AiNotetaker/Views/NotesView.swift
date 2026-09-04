import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var api: APIClient
    @State private var notes: [Note] = []
    @State private var search = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var editing: Note?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("Notes")
            .searchable(text: $search, prompt: "Search your notes")
            .onChange(of: search) { _, _ in Task { await load() } }
            .refreshable { await load() }
            .task { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Create note")
                    .disabled(!api.isConfigured)
                }
            }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { note in
                NoteEditorView(note: note)
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
                NoteEditorView(note: nil)
            }
            .alert("Notes", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !api.isConfigured {
            ContentUnavailableView {
                Label("Connect your private server", systemImage: "server.rack")
            } description: {
                Text("Add the server address in Settings to sync and search your notes.")
            }
        } else if notes.isEmpty && !loading {
            ContentUnavailableView {
                Label(search.isEmpty ? "A quiet place for your thoughts" : "No matching notes",
                      systemImage: search.isEmpty ? "note.text" : "magnifyingglass")
            } description: {
                Text(search.isEmpty
                     ? "Write a note here, or turn any recording transcript into one."
                     : "Try a different word or phrase.")
            } actions: {
                if search.isEmpty {
                    Button("Create Note") { creating = true }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                }
            }
        } else {
            List {
                notesSummary
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(notes) { note in
                    Button { editing = note } label: { NoteRow(note: note) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onDelete(perform: delete)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 16, for: .scrollContent)
            .overlay {
                if loading && notes.isEmpty {
                    AppCard {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading your notes…")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(30)
                }
            }
        }
    }

    private var notesSummary: some View {
        AppCard {
            HStack(spacing: 14) {
                BrandMark(systemImage: "note.text")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Private Notes")
                        .font(.title3.weight(.bold))
                    Text("Thoughts and transcripts, in one place")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(notes.count)")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("\(notes.count) notes")
            }
        }
    }

    private func load() async {
        guard api.isConfigured else { return }
        loading = true
        defer { loading = false }
        do {
            notes = try await api.listNotes(query: search)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { notes[$0] }
        notes.remove(atOffsets: offsets)
        Task {
            for note in targets { try? await api.deleteNote(note.id) }
        }
    }
}

struct NoteRow: View {
    let note: Note

    private var primary: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let snippet = (note.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? "New Note" : snippet
    }

    private var secondary: String? {
        guard !note.title.isEmpty else { return nil }
        let snippet = (note.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: note.pinned ? "pin.fill" : "note.text")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(note.pinned ? AppTheme.accent : Color.secondary)
                .frame(width: 42, height: 42)
                .background(
                    (note.pinned ? AppTheme.accent : Color.secondary).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(primary)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if note.pinned {
                        Text("PINNED")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                .autoDirection(for: primary)

                if let secondary {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .autoDirection(for: secondary)
                }

                Text(formatServerDate(note.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
        .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
