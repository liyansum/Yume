import Foundation
import SwiftUI
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct LibraryView: View {
    enum LayoutMode: String {
        case grid
        case list
    }

    let model: AppModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("library.layout.compact") private var compactLayout = LayoutMode.grid.rawValue
    @AppStorage("library.layout.regular") private var regularLayout = LayoutMode.grid.rawValue
    @State private var searchText = ""
    @State private var sort = LibrarySort.recentlyPlayed
    @State private var presentsFileImporter = false
    @State private var archivePassword = ""
    @State private var pendingDeletion: ImportedGame?
    @State private var pendingRename: ImportedGame?
    @State private var renameTitle = ""
    @State private var libraryOperationFailed = false

    private var layout: LayoutMode {
        get {
            LayoutMode(rawValue: horizontalSizeClass == .regular ? regularLayout : compactLayout) ?? .grid
        }
        nonmutating set {
            if horizontalSizeClass == .regular {
                regularLayout = newValue.rawValue
            } else {
                compactLayout = newValue.rawValue
            }
        }
    }

    private var visibleGames: [ImportedGame] {
        LibraryQuery(searchText: searchText, sort: sort).apply(to: model.games)
    }

    var body: some View {
        Group {
            if model.isLoadingLibrary {
                ProgressView("library.loading")
            } else if model.libraryLoadFailed {
                ContentUnavailableView {
                    Label("library.error.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("library.error.message")
                } actions: {
                    Button("common.retry") {
                        Task { await model.reloadLibrary() }
                    }
                }
            } else if model.games.isEmpty {
                emptyLibrary
            } else if visibleGames.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $searchText, prompt: "library.search.prompt")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $presentsFileImporter,
            allowedContentTypes: [.folder, .zip, UTType(filenameExtension: "7z") ?? .data],
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
        .overlay {
            if model.isImporting {
                ImportProgressOverlay(progress: model.importProgress)
            }
        }
        .alert(importAlertTitle, isPresented: importNoticeBinding) {
            Button("common.ok", role: .cancel) {
                model.dismissImportNotice()
            }
        } message: {
            Text(importAlertMessage)
        }
        .alert(archivePasswordTitle, isPresented: archivePasswordBinding) {
            SecureField("import.password.placeholder", text: $archivePassword)
                .textContentType(.password)
            Button("common.cancel", role: .cancel) {
                archivePassword = ""
                model.cancelArchivePassword()
            }
            Button("import.password.unlock") {
                let password = archivePassword
                archivePassword = ""
                model.submitArchivePassword(password)
            }
            .disabled(archivePassword.isEmpty)
        } message: {
            Text("import.password.message")
        }
        .sheet(isPresented: detectionChoiceBinding) {
            if let choice = model.detectionChoice {
                DetectionChoiceView(
                    candidates: choice.candidates,
                    choose: model.chooseDetection,
                    cancel: model.cancelDetectionChoice
                )
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
        }
        .confirmationDialog(
            "import.duplicate.title",
            isPresented: duplicateChoiceBinding,
            titleVisibility: .visible
        ) {
            Button("import.duplicate.keepBoth") {
                model.resolveDuplicateChoice(.keepBoth)
            }
            Button("import.duplicate.replace", role: .destructive) {
                model.resolveDuplicateChoice(.replaceExisting)
            }
            Button("common.cancel", role: .cancel) {
                model.resolveDuplicateChoice(.cancel)
            }
        } message: {
            if let existing = model.duplicateChoice?.existingGame {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "import.duplicate.message"),
                        existing.title
                    )
                )
            }
        }
        .confirmationDialog(
            "game.delete.quick.title",
            isPresented: pendingDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("game.delete.quick.confirm", role: .destructive) {
                guard let game = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    libraryOperationFailed = !(await model.remove(game, policy: .preserveSaves))
                }
            }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("game.delete.quick.message")
        }
        .alert("game.rename.title", isPresented: pendingRenameBinding) {
            TextField("game.rename.placeholder", text: $renameTitle)
            Button("common.cancel", role: .cancel) { pendingRename = nil }
            Button("common.save") {
                guard let game = pendingRename else { return }
                pendingRename = nil
                Task {
                    libraryOperationFailed = !(await model.rename(game, to: renameTitle))
                }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("library.operation.error.title", isPresented: $libraryOperationFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("library.operation.error.message")
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "gamecontroller")
        } description: {
            Text("library.empty.message")
        } actions: {
            Button("library.import.action") {
                presentsFileImporter = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                libraryHeader

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 220 : 160), spacing: 14)],
                    spacing: 16
                ) {
                    ForEach(visibleGames) { game in
                        NavigationLink {
                            GameDetailView(game: game, model: model)
                        } label: {
                            GameGridItem(game: game)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            gameActions(for: game)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var list: some View {
        List(visibleGames) { game in
            NavigationLink {
                GameDetailView(game: game, model: model)
            } label: {
                GameListItem(game: game)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeletion = game
                } label: {
                    Label("game.delete", systemImage: "trash")
                }
                .tint(.red)

                Button {
                    beginRename(game)
                } label: {
                    Label("game.rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu { gameActions(for: game) }
        }
        .listStyle(.insetGrouped)
    }

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("library.collection.title")
                    .font(.headline)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "library.collection.count"),
                        Int64(visibleGames.count)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func gameActions(for game: ImportedGame) -> some View {
        Button {
            beginRename(game)
        } label: {
            Label("game.rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            pendingDeletion = game
        } label: {
            Label("game.delete", systemImage: "trash")
        }
    }

    private func beginRename(_ game: ImportedGame) {
        renameTitle = game.title
        pendingRename = game
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.recoveredTasks.isEmpty {
                NavigationLink {
                    ImportTaskCenterView(model: model)
                } label: {
                    Label("library.tasks", systemImage: "circle.dashed")
                }
            }

            Menu {
                Picker("library.sort.title", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { option in
                        Text(option.localizedKey).tag(option)
                    }
                }
            } label: {
                Label("library.sort.title", systemImage: "arrow.up.arrow.down")
            }

            Button {
                layout = layout == .grid ? .list : .grid
            } label: {
                Label(
                    layout == .grid ? "library.layout.list" : "library.layout.grid",
                    systemImage: layout == .grid ? "list.bullet" : "square.grid.2x2"
                )
            }

            Button {
                presentsFileImporter = true
            } label: {
                Label("library.import.action", systemImage: "plus")
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard !urls.isEmpty else { return }
            Task { await model.importSources(urls) }
        case .failure:
            break
        }
    }

    private var importNoticeBinding: Binding<Bool> {
        Binding(
            get: { model.importNotice != nil },
            set: { if !$0 { model.dismissImportNotice() } }
        )
    }

    private var detectionChoiceBinding: Binding<Bool> {
        Binding(
            get: { model.detectionChoice != nil },
            set: { if !$0 { model.cancelDetectionChoice() } }
        )
    }

    private var duplicateChoiceBinding: Binding<Bool> {
        Binding(
            get: { model.duplicateChoice != nil },
            set: { if !$0, model.duplicateChoice != nil { model.resolveDuplicateChoice(.cancel) } }
        )
    }

    private var archivePasswordBinding: Binding<Bool> {
        Binding(
            get: { model.archivePasswordChoice != nil },
            set: { presented in
                if !presented, model.archivePasswordChoice != nil {
                    archivePassword = ""
                    model.cancelArchivePassword()
                }
            }
        )
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var pendingRenameBinding: Binding<Bool> {
        Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )
    }

    private var archivePasswordTitle: LocalizedStringKey {
        model.archivePasswordChoice?.isRetry == true
            ? "import.password.retry.title"
            : "import.password.title"
    }

    private var importAlertTitle: LocalizedStringKey {
        guard let notice = model.importNotice else { return "import.result.failure.title" }
        switch notice.kind {
        case .success: return "import.result.success.title"
        case .partialSuccess: return "import.result.partial.title"
        case .failure: return "import.result.failure.title"
        }
    }

    private var importAlertMessage: LocalizedStringKey {
        guard let notice = model.importNotice else { return "import.failure.unreadable" }
        switch notice.kind {
        case .success:
            return "import.result.success.message"
        case .partialSuccess(_, let failure), .failure(let failure):
            return failure.localizedKey
        }
    }
}

private struct DetectionChoiceView: View {
    let candidates: [ProbeResult]
    let choose: (ProbeResult) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                Button {
                    choose(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.engine.displayName)
                            .font(.headline)
                        Text(candidate.rootRelativePath.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "import.ambiguity.confidence"),
                                Int64(candidate.confidence)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("import.ambiguity.title")
            .safeAreaInset(edge: .bottom) {
                Text("import.ambiguity.message")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", action: cancel)
                }
            }
        }
    }
}

private struct ImportProgressOverlay: View {
    let progress: GameImportProgress?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(progress?.localizedKey ?? "import.progress.validating")
                .font(.headline)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 18)
        .accessibilityElement(children: .combine)
    }
}

private extension GameImportProgress {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .validating: "import.progress.validating"
        case .budgeting: "import.progress.budgeting"
        case .copying: "import.progress.copying"
        case .detecting: "import.progress.detecting"
        case .committing: "import.progress.committing"
        }
    }
}

private extension AppModel.ImportNotice.Failure {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .archiveNotAvailable: "import.failure.archiveNotAvailable"
        case .encryptedArchive: "import.failure.encryptedArchive"
        case .unsupportedArchive: "import.failure.unsupportedArchive"
        case .unsafeArchive: "import.failure.unsafeArchive"
        case .insufficientStorage: "import.failure.insufficientStorage"
        case .noSupportedGame: "import.failure.noSupportedGame"
        case .ambiguous: "import.failure.ambiguous"
        case .unsupported: "import.failure.unsupported"
        case .unsupportedNativeComponent: "import.failure.nativeComponent"
        case .invalidEngineArchive: "import.failure.invalidEngineArchive"
        case .unreadableEngineArchive: "import.failure.unreadableEngineArchive"
        case .runtimeUnavailable: "import.failure.runtimeUnavailable"
        case .duplicate: "import.failure.duplicate"
        case .unreadable: "import.failure.unreadable"
        }
    }
}

private extension LibrarySort {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .recentlyPlayed: "library.sort.recentlyPlayed"
        case .title: "library.sort.name"
        case .recentlyImported: "library.sort.recentlyImported"
        case .size: "library.sort.size"
        }
    }
}
