import SwiftUI
import UIKit

struct NoteEditorView: View {
    let note: Note?
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var pinned = false
    @State private var saving = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(note == nil ? "NEW NOTE" : "PRIVATE NOTE")
                                .font(.caption2.weight(.bold))
                                .tracking(1.1)
                                .foregroundStyle(AppTheme.accent)
                            if pinned {
                                Label("Pinned", systemImage: "pin.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.accent.opacity(0.10), in: Capsule())
                            }
                        }

                        TextField("Title", text: $title, axis: .vertical)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .title)
                            .autoDirection(for: title)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                        .padding(.horizontal, 20)

                    TextEditor(text: $content)
                        .font(.body)
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .content)
                        .autoDirection(for: content)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("Write anything you want to remember…")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05))
                }
                .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

                if saving {
                    ProgressView("Saving…")
                        .padding(18)
                        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
                }
            }
            .navigationTitle(note == nil ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(saving ? "Saving…" : "Done") { save() }
                        .fontWeight(.semibold)
                        .disabled(saving || (title.isEmpty && content.isEmpty))
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        pinned.toggle()
                    } label: {
                        Label(pinned ? "Unpin Note" : "Pin Note", systemImage: pinned ? "pin.slash" : "pin")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .task { await loadFull() }
            .interactiveDismissDisabled(saving)
            .alert("Note", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadFull() async {
        guard !loaded else { return }
        loaded = true
        guard let note else {
            focusedField = .title
            return
        }
        title = note.title
        pinned = note.pinned
        if let existing = note.content {
            content = existing
        } else if let full = try? await api.getNote(note.id) {
            title = full.title
            content = full.content ?? ""
            pinned = full.pinned
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                if let note {
                    _ = try await api.updateNote(note.id, title: title, content: content, pinned: pinned)
                } else {
                    let created = try await api.createNote(title: title, content: content)
                    if pinned { _ = try await api.updateNote(created.id, pinned: true) }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            saving = false
        }
    }
}
