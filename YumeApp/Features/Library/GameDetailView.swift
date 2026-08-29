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
    @State private var presentsSaveImporter = false
    @State private var presentsSaveLibraryPicker = false
    @State private var currentSaveLibrary: GameSaveLibrary?
    @State private var presentsRename = false
    @State private var renameTitle = ""
    @State private var renameFailed = false
    @State private var exportedSaveURL: URL?
    @State private var saveOperationFailed = false
    @State private var removalFailed = false
    @State private var renpyBand: RenPyRuntimeBand = .automatic

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.engine.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(game.installedByteCount, format: .byteCount(style: .file))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("game.compatibility.title") {
                LabeledContent("game.compatibility.engine", value: game.engine.compatibilityVersion)
                LabeledContent("game.compatibility.status") {
                    Text(compatibilityText)
                }
            }

            if game.engine.id.rawValue == "renpy" {
                Section("game.renpy.runtime.title") {
                    Picker("game.renpy.runtime.title", selection: $renpyBand) {
                        Text("game.renpy.runtime.auto").tag(RenPyRuntimeBand.automatic)
                        Text("game.renpy.runtime.legacy").tag(RenPyRuntimeBand.legacy7)
                        Text("game.renpy.runtime.modern").tag(RenPyRuntimeBand.modern8)
                    }
                    .onChange(of: renpyBand) { _, band in
                        GameRuntimePreferences.setRenpyBand(band, for: game.id)
                    }
                    Text("game.renpy.runtime.help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await model.launch(game) }
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Label("game.play", systemImage: "play.fill")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(game.compatibilityStatus != .runnable)
            }
            .listRowBackground(Color.clear)

            Section("game.saves.title") {
                if let currentSaveLibrary {
                    LabeledContent("game.saves.bound") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(currentSaveLibrary.title)
                            Text(currentSaveLibrary.byteCount, format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    presentsSaveLibraryPicker = true
                } label: {
                    Label("game.saves.choose", systemImage: "link")
                }

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
                        removalFailed = removalBreakdown == nil
                    }
                }
            }
        }
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            currentSaveLibrary = await model.saveLibrary(for: game)
            if game.engine.id.rawValue == "renpy" {
                renpyBand = GameRuntimePreferences.renpyBand(for: game.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameTitle = game.title
                        presentsRename = true
                    } label: {
                        Label("game.rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        Task {
                            removalBreakdown = await model.storageBreakdown(for: game)
                            removalFailed = removalBreakdown == nil
                        }
                    } label: {
                        Label("game.delete", systemImage: "trash")
                    }
                } label: {
                    Label("common.more", systemImage: "ellipsis.circle")
                }
            }
        }
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
        .sheet(item: $removalBreakdown) { breakdown in
            GameRemovalView(
                    game: game,
                    breakdown: breakdown,
                    policy: $removalPolicy,
                    exportedSaveURL: $exportedSaveURL,
                    exportSaves: {
                        exportedSaveURL = await model.exportSaves(for: game)
                    },
                    confirm: {
                        let removed = await model.remove(game, policy: removalPolicy)
                        if removed {
                            removalBreakdown = nil
                            dismiss()
                        } else {
                            removalFailed = true
                        }
                    }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $presentsSaveLibraryPicker) {
            SaveLibraryPicker(
                game: game,
                current: currentSaveLibrary,
                libraries: model.saveLibraries,
                choose: { library in
                    if await model.bindSaveLibrary(library, to: game) {
                        currentSaveLibrary = await model.saveLibrary(for: game)
                        presentsSaveLibraryPicker = false
                    } else {
                        saveOperationFailed = true
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .alert("game.rename.title", isPresented: $presentsRename) {
            TextField("game.rename.placeholder", text: $renameTitle)
            Button("common.cancel", role: .cancel) {}
            Button("common.save") {
                Task {
                    if await model.rename(game, to: renameTitle) {
                        dismiss()
                    } else {
                        renameFailed = true
                    }
                }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("game.rename.error.title", isPresented: $renameFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("game.rename.error.message")
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

private struct SaveLibraryPicker: View {
    let game: ImportedGame
    let current: GameSaveLibrary?
    let libraries: [GameSaveLibrary]
    let choose: (GameSaveLibrary) async -> Void

    @Environment(\.dismiss) private var dismiss

    private var compatibleLibraries: [GameSaveLibrary] {
        libraries.filter { library in
            library.engine == game.engine
                && (library.boundGameID == nil || library.id == current?.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("game.saves.choose.message")
                        .foregroundStyle(.secondary)
                }
                Section("game.saves.available") {
                    ForEach(compatibleLibraries) { library in
                        Button {
                            Task { await choose(library) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.title)
                                        .foregroundStyle(.primary)
                                    Text(library.byteCount, format: .byteCount(style: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if library.id == current?.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("game.saves.choose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
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

                Section {
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
                } header: {
                    Text("game.delete.saves.title")
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
