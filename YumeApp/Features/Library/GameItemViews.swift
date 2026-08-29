import SwiftUI
import UIKit
import YumeDomain

struct GameGridItem: View {
    let game: ImportedGame
    var artworkURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            GameArtworkView(game: game, artworkURL: artworkURL)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(minHeight: 96)

            Text(game.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(game.engine.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                CompatibilityBadge(status: game.compatibilityStatus, compact: true)
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

struct GameListItem: View {
    let game: ImportedGame
    var artworkURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            GameArtworkView(game: game, artworkURL: artworkURL)
                .frame(width: 88, height: 55)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(game.engine.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                CompatibilityBadge(status: game.compatibilityStatus, compact: false)
            }

            Spacer(minLength: 8)

            Text(game.installedByteCount, format: .byteCount(style: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct GameArtworkView: View {
    let game: ImportedGame
    var artworkURL: URL?

    private var hue: Double {
        let bytes = game.id.rawValue.uuid
        return Double(bytes.0) / 255
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.28, brightness: 0.34),
                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let artworkURL, let image = UIImage(contentsOfFile: artworkURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack {
                Spacer()
                HStack {
                    Text(game.engine.displayName)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(8)
                .background(.black.opacity(0.28))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct CompatibilityBadge: View {
    let status: CompatibilityStatus
    let compact: Bool

    @ViewBuilder
    var body: some View {
        if compact {
            badgeLabel
                .labelStyle(.iconOnly)
        } else {
            badgeLabel
        }
    }

    private var badgeLabel: some View {
        Label(status.localizedKey, systemImage: status.symbolName)
            .font(.caption)
            .foregroundStyle(status.tint)
            .accessibilityLabel(Text(status.localizedKey))
    }
}

private extension CompatibilityStatus {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .runnable: "compatibility.runnable"
        case .conversionRequired: "compatibility.conversionRequired"
        case .partiallyCompatible: "compatibility.partiallyCompatible"
        case .unsupported: "compatibility.unsupported"
        case .notEvaluated: "compatibility.notEvaluated"
        }
    }

    var symbolName: String {
        switch self {
        case .runnable: "checkmark.circle.fill"
        case .conversionRequired: "arrow.triangle.2.circlepath.circle.fill"
        case .partiallyCompatible: "exclamationmark.circle.fill"
        case .unsupported: "xmark.circle.fill"
        case .notEvaluated: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .runnable: .green
        case .conversionRequired: .blue
        case .partiallyCompatible: .orange
        case .unsupported: .red
        case .notEvaluated: .gray
        }
    }
}
