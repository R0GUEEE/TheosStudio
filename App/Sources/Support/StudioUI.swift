import SwiftUI

enum StudioUI {
    static let cardRadius: CGFloat = 20
    static let compactRadius: CGFloat = 13
    static let spacing: CGFloat = 14
    static let pageInset: CGFloat = 16

    static let accent = Color.indigo
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    static func schemeColor(_ scheme: String) -> Color {
        switch scheme.lowercased() {
        case "rootless": return .blue
        case "roothide": return .purple
        case "rootful": return .orange
        default: return .secondary
        }
    }
}

struct StudioCard<Content: View>: View {
    var padding: CGFloat = StudioUI.spacing
    let content: Content

    init(padding: CGFloat = StudioUI.spacing, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: StudioUI.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudioUI.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.75)
            )
    }
}

struct StudioHero<Content: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let content: Content

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        StudioCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(tint.opacity(0.14))
                        Image(systemName: systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(tint)
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        if let eyebrow {
                            Text(eyebrow.uppercased())
                                .font(.caption2.weight(.bold))
                                .tracking(0.8)
                                .foregroundColor(tint)
                        }
                        Text(title)
                            .font(.title2.weight(.bold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                content
            }
        }
    }
}

struct StudioSectionTitle: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct StudioMetric: View {
    let title: String
    let value: String
    var systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(tint)
                Spacer()
            }
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(tint.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: StudioUI.compactRadius, style: .continuous))
    }
}

struct StudioEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.09))
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 64, height: 64)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

struct StudioStatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.35), radius: 3)
    }
}

struct StudioPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct StudioActionButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}
