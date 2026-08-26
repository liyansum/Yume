import YumeDomain

public protocol GameLibrary: Sendable {
    func allGames() async throws -> [ImportedGame]
}

public enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case recentlyPlayed
    case title
    case recentlyImported
    case size
}

public struct LibraryQuery: Sendable, Equatable {
    public var searchText: String
    public var sort: LibrarySort

    public init(searchText: String = "", sort: LibrarySort = .recentlyPlayed) {
        self.searchText = searchText
        self.sort = sort
    }

    public func apply(to games: [ImportedGame]) -> [ImportedGame] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmedSearch.isEmpty
            ? games
            : games.filter { game in
                game.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || game.engine.displayName.localizedCaseInsensitiveContains(trimmedSearch)
            }

        return filtered.sorted(by: comparator)
    }

    private func comparator(_ lhs: ImportedGame, _ rhs: ImportedGame) -> Bool {
        switch sort {
        case .recentlyPlayed:
            let lhsDate = lhs.lastPlayedAt ?? .distantPast
            let rhsDate = rhs.lastPlayedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .recentlyImported:
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
        case .size:
            if lhs.installedByteCount != rhs.installedByteCount {
                return lhs.installedByteCount > rhs.installedByteCount
            }
        }

        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
