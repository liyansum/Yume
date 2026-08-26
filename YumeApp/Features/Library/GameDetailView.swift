import SwiftUI
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct GameDetailView: View {
    let game: ImportedGame
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var removalBreakdown: GameStorageBreakdown?
    @State private var removalPolicy = GameRemovalPolicy.preserveSaves
    @State private var presentsRemoval = false
    @State private var presentsSaveImporter = false
    @State private var exportedSaveURL: URL?
    @State private var saveOperationFailed = false
    @State private var removalFailed = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(game.title)
                        .font(.largeTitle.bold())
                    Text(game.engine.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(game.installedByteCount, format: .byteCount(style: .file))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("game.compatibility.title") {
                LabeledContent("game.compatibility.engine", value: game.engine.compatibilityVersion)
                LabeledContent("game.compatibility.status") {
                    Text(compatibilityText)
                }
            }

            Section {
                Button {
                    Task { await model.launch(game) }
                } label: {
                    Label("game.play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(game.compatibilityStatus != .runnable)
            }
            .listRowBackground(Color.clear)

            Section("game.saves.title") {
                Button {
                    Task {
                        exportedSaveURL = await model.exportSaves(for: game)
                        saveOperationFailed = exportedSaveURL == nil
                    }
                } label: {
                    Label("game.saves.export", systemImage: "square.and.arrow.up")
                }

                if let exportedSaveURL {
                    ShareLink(item: exportedSaveURL) {
                        Label("game.saves.share", systemImage: "paperplane")
                    }
                }

                Button {
                    presentsSaveImporter = true
                } label: {
                    Label("game.saves.import", systemImage: "square.and.arrow.down")
                }
            }

            Section {
                Button("game.delete", role: .destructive) {
                    Task {
                        removalBreakdown = await model.storageBreakdown(for: game)
                        presentsRemoval = removalBreakdown != nil
                        removalFailed = removalBreakdown == nil
                    }
                }
            }
        }
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $presentsSaveImporter,
            allowedContentTypes: [savePackageType],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                saveOperationFailed = true
                return
            }
            Task {
                saveOperationFailed = !(await model.importSaves(from: url, for: game))
            }
        }
        .sheet(isPresented: $presentsRemoval) {
            if let removalBreakdown {
                GameRemovalView(
                    game: game,
                    breakdown: removalBreakdown,
                    policy: $removalPolicy,
                    exportedSaveURL: $exportedSaveURL,
                    exportSaves: {
                        exportedSaveURL = await model.exportSaves(for: game)
                    },
                    confirm: {
                        let removed = await model.remove(game, policy: removalPolicy)
                        if removed {
                            presentsRemoval = false
                            dismiss()
                        } else {
                            removalFailed = true
                        }
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .alert("game.saves.error.title", isPresented: $saveOperationFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("game.saves.error.message")
        }
        .alert("game.delete.error.title", isPresented: $removalFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("game.delete.error.message")
        }
    }

    private var compatibilityText: LocalizedStringKey {
        switch game.compatibilityStatus {
        case .runnable: "compatibility.runnable"
        case .conversionRequired: "compatibility.conversionRequired"
        case .partiallyCompatible: "compatibility.partiallyCompatible"
        case .unsupported: "compatibility.unsupported"
        case .notEvaluated: "compatibility.notEvaluated"
        }
    }

    private var savePackageType: UTType {
        UTType(filenameExtension: "yumesave", conformingTo: .data) ?? .data
    }
}

private struct GameRemovalView: View {
    let game: ImportedGame
    let breakdown: GameStorageBreakdown
    @Binding var policy: GameRemovalPolicy
    @Binding var exportedSaveURL: URL?
    let exportSaves: () async -> Void
    let confirm: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("game.delete.storage.title") {
                    LabeledContent("game.delete.storage.original") {
                        Text(breakdown.originalByteCount, format: .byteCount(style: .file))
                    }
                    LabeledContent("game.delete.storage.derived") {
                        Text(breakdown.derivedByteCount, format: .byteCount(style: .file))
                    }
                    LabeledContent("game.delete.storage.saves") {
                        Text(breakdown.saveByteCount, format: .byteCount(style: .file))
                    }
                }

                Section("game.delete.saves.title") {
                    Picker("game.delete.saves.choice", selection: $policy) {
                        Text("game.delete.saves.preserve").tag(GameRemovalPolicy.preserveSaves)
                        Text("game.delete.saves.delete").tag(GameRemovalPolicy.deleteSaves)
                    }
                    .pickerStyle(.inline)

                    if policy == .deleteSaves {
                        Button("game.saves.export") {
                            Task { await exportSaves() }
                        }
                        if let exportedSaveURL {
                            ShareLink("game.saves.share", item: exportedSaveURL)
                        }
                    }
                } footer: {
                    Text(removalMessage)
                }

                Section {
                    Button("game.delete.confirm", role: .destructive) {
                        Task { await confirm() }
                    }
                }
            }
            .navigationTitle(game.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }

    private var removalMessage: LocalizedStringKey {
        policy == .preserveSaves
            ? "game.delete.saves.preserve.message"
            : "game.delete.saves.delete.message"
    }
}
