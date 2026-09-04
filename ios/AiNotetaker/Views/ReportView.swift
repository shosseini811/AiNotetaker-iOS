import SwiftUI

struct ReportView: View {
    @EnvironmentObject private var api: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var instructions = ""
    @State private var saveAsNote = true
    @State private var report: String?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        introCard
                        requestCard
                        if let report {
                            resultCard(report)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 16)
                }

                if busy {
                    ProgressView("Building your report…")
                        .padding(20)
                        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                }
            }
            .navigationTitle("AI Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .alert("Report", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var introCard: some View {
        AppCard {
            HStack(spacing: 14) {
                BrandMark(systemImage: "sparkles", size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect the dots")
                        .font(.title3.weight(.bold))
                    Text("Turn your recordings and notes into one focused brief.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var requestCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 15) {
                SectionHeading(title: "What should the report focus on?", systemImage: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 6) {
                    Text("TITLE")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    TextField("Optional report title", text: $title)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(AppTheme.quietSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("INSTRUCTIONS")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    TextField("For example: focus on decisions and next steps", text: $instructions, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(AppTheme.quietSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Toggle(isOn: $saveAsNote) {
                    Label("Save the result as a note", systemImage: "note.text.badge.plus")
                        .font(.subheadline.weight(.medium))
                }

                Button { generate() } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text(busy ? "Generating…" : "Generate Report")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(busy || !api.isConfigured)
            }
        }
    }

    private func resultCard(_ report: String) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionHeading(title: "Your Report", subtitle: "Ready to use", systemImage: "checkmark.seal.fill")
                    ShareLink(item: report) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .background(AppTheme.accent.opacity(0.10), in: Circle())
                    }
                    .accessibilityLabel("Share report")
                }

                Text(rendered(report))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .autoDirection(for: report)
            }
        }
    }

    private func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private func generate() {
        busy = true
        Task {
            do {
                let response = try await api.generateReport(instructions: instructions, title: title, saveAsNote: saveAsNote)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                    report = response.report
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
