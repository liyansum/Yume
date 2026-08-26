import Foundation
import Observation
import YumeApplication
import YumeDomain
import YumeInfrastructure

@MainActor
@Observable
final class AppModel {
    private let library: any GameLibrary
    private var hasLoaded = false

    private(set) var games: [ImportedGame] = []
    private(set) var isLoadingLibrary = false
    private(set) var libraryLoadFailed = false

    init(library: any GameLibrary = InMemoryGameLibrary()) {
        self.library = library
    }

    func loadLibraryIfNeeded() async {
        guard !hasLoaded else { return }
        await reloadLibrary()
    }

    func reloadLibrary() async {
        isLoadingLibrary = true
        libraryLoadFailed = false

        do {
            games = try await library.allGames()
            hasLoaded = true
        } catch {
            libraryLoadFailed = true
        }

        isLoadingLibrary = false
    }
}
