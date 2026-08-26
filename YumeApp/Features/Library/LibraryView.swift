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
    @State private var presentsImportResult = false
    @State private var selectedSourceCount = 0
    @State private var selectionFailed = false

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
            allowedContentTypes: supportedImportTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
        .alert("import.development.title", isPresented: $presentsImportResult) {
            Button("common.ok", role: .cancel) {}
        } message: {
            if selectionFailed {
                Text("import.selection.failed")
            } else {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "import.development.message"),
                        selectedSourceCount
                    )
                )
            }
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 190 : 150), spacing: 16)],
                spacing: 20
            ) {
                ForEach(visibleGames) { game in
                    GameGridItem(game: game)
                }
            }
            .padding()
        }
    }

    private var list: some View {
        List(visibleGames) { game in
            GameListItem(game: game)
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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

    private var supportedImportTypes: [UTType] {
        var types: [UTType] = [.zip, .folder]
        if let sevenZip = UTType(filenameExtension: "7z") {
            types.append(sevenZip)
        }
        return types
    }

    private func handleFileSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard !urls.isEmpty else { return }
            selectedSourceCount = urls.count
            selectionFailed = false
        case .failure:
            selectedSourceCount = 0
            selectionFailed = true
        }
        presentsImportResult = true
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
