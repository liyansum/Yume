import SwiftUI
import YumeApplication
import YumeDomain

struct DeveloperDiagnosticsView: View {
    let model: AppModel

    private var recentEntries: [DiagnosticEntry] {
        Array(model.diagnosticEntries.suffix(200).reversed())
    }

    var body: some View {
        List {
            Section("diagnostics.dev.entries.title") {
                ForEach(recentEntries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: symbolName(for: entry.level))
                            .foregroundStyle(tint(for: entry.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.subsystem)
                                .font(.subheadline.weight(.medium))
                            Text(entry.code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            }

            Section("diagnostics.dev.catalog.title") {
                HStack {
                    Spacer()
                    Text("diagnostics.dev.catalog.hosting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(model.engineCatalog.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.descriptor.displayName)
                            Text(entry.descriptor.compatibilityVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(
                            entry.hostingKind.localizedKey,
                            systemImage: entry.hostingKind.symbolName
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(entry.hostingKind.tint)
                        .accessibilityLabel(Text(entry.hostingKind.localizedKey))
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section("diagnostics.export.title") {
                Button("diagnostics.export.prepare") {
                    Task { await model.prepareDiagnosticExport() }
                }
                if let exportURL = model.diagnosticExportURL {
                    ShareLink("diagnostics.export.share", item: exportURL)
                }
            }
        }
        .navigationTitle("diagnostics.dev.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshDiagnostics()
        }
    }

    private func symbolName(for level: DiagnosticLevel) -> String {
        switch level {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func tint(for level: DiagnosticLevel) -> Color {
        switch level {
        case .information: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private extension EngineHostingKind {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .restrictedWeb: "hosting.restrictedWeb"
        case .dedicatedRuntime: "hosting.dedicatedRuntime"
        case .detectionOnly: "hosting.detectionOnly"
        }
    }

    var symbolName: String {
        switch self {
        case .restrictedWeb: "checkmark.circle.fill"
        case .dedicatedRuntime: "shippingbox.circle.fill"
        case .detectionOnly: "magnifyingglass.circle"
        }
    }

    var tint: Color {
        switch self {
        case .restrictedWeb: .green
        case .dedicatedRuntime: .blue
        case .detectionOnly: .orange
        }
    }
}
