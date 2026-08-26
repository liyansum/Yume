import SwiftUI
import YumeDomain

struct GameGridItem: View {
    let game: ImportedGame

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GameArtworkPlaceholder(gameID: game.id)
                .aspectRatio(3 / 4, contentMode: .fit)

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
        .accessibilityElement(children: .combine)
    }
}

struct GameListItem: View {
    let game: ImportedGame

    var body: some View {
        HStack(spacing: 14) {
            GameArtworkPlaceholder(gameID: game.id)
                .frame(width: 64, height: 84)

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

private struct GameArtworkPlaceholder: View {
    let gameID: GameID

    private var hue: Double {
        let bytes = gameID.rawValue.uuid
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

            Image(systemName: "gamecontroller")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
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
