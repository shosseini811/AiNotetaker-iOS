import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(red: 0.36, green: 0.31, blue: 0.92)
    static let accentSecondary = Color(red: 0.66, green: 0.30, blue: 0.91)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let quietSurface = Color(uiColor: .tertiarySystemGroupedBackground)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            AppTheme.canvas
            Circle()
                .fill(AppTheme.accent.opacity(0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: -150, y: -300)
            Circle()
                .fill(AppTheme.accentSecondary.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 90)
                .offset(x: 170, y: 260)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
            .shadow(color: Color.black.opacity(0.055), radius: 18, y: 8)
    }
}

struct BrandMark: View {
    let systemImage: String
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AppTheme.brandGradient, in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(.white.opacity(0.22))
            }
            .shadow(color: AppTheme.accent.opacity(0.23), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct MetadataPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppTheme.quietSurface, in: Capsule())
    }
}

enum TextDirection {
    /// True when the first strong character belongs to a right-to-left script
    /// (Hebrew, Arabic, Persian, Urdu, ...). Neutral characters — digits,
    /// punctuation, spaces — are skipped, so direction follows the first real word.
    static func isRTL(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x0590...0x05FF).contains(value)      // Hebrew
                || (0x0600...0x06FF).contains(value)  // Arabic, Persian, Urdu
                || (0x0700...0x074F).contains(value)  // Syriac
                || (0x0750...0x077F).contains(value)  // Arabic Supplement
                || (0x08A0...0x08FF).contains(value)  // Arabic Extended-A
                || (0xFB1D...0xFDFF).contains(value)  // Hebrew/Arabic presentation forms
                || (0xFE70...0xFEFF).contains(value) {// Arabic presentation forms-B
                return true
            }
            if (0x0041...0x005A).contains(value) || (0x0061...0x007A).contains(value) {
                return false
            }
        }
        return false
    }
}

extension View {
    /// Aligns text for its own script: right-to-left languages trail, others lead.
    func autoDirection(for text: String) -> some View {
        let rtl = TextDirection.isRTL(text)
        return self
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func formatServerDate(_ iso: String) -> String {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = plain.date(from: iso) ?? fractional.date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .shortened)
}

struct StatusBadge: View {
    let status: String

    private var descriptor: (text: String, icon: String, color: Color) {
        switch status {
        case "done": return ("Ready", "checkmark.circle.fill", .green)
        case "processing": return ("Processing", "sparkles", .orange)
        case "uploading": return ("Uploading", "arrow.up.circle.fill", .orange)
        case "queued": return ("Waiting for connection", "clock.arrow.circlepath", .orange)
        case "uploaded": return ("Uploaded", "icloud.fill", .blue)
        case "error": return ("Needs attention", "exclamationmark.circle.fill", .red)
        case "local": return ("On device", "iphone", .secondary)
        default: return (status.capitalized, "circle.fill", .secondary)
        }
    }

    var body: some View {
        Label(descriptor.text, systemImage: descriptor.icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(descriptor.color.opacity(0.13), in: Capsule())
            .foregroundStyle(descriptor.color)
            .accessibilityLabel("Status: \(descriptor.text)")
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<28, id: \.self) { index in
                let distance = abs(CGFloat(index) - 13.5) / 13.5
                let threshold = Float(index) / 28
                let active = level > threshold
                let activeColor: Color = threshold > 0.84
                    ? .red
                    : (threshold > 0.67 ? .orange : AppTheme.accent)
                Capsule()
                    .fill(active ? activeColor : Color.secondary.opacity(0.13))
                    .frame(width: 4, height: 18 + (1 - distance) * 25)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
