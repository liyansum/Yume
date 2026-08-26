import SwiftUI

struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case library
        case settings

        var id: Self { self }

        var titleKey: LocalizedStringKey {
            switch self {
            case .library: "navigation.library"
            case .settings: "navigation.settings"
            }
        }

        var symbolName: String {
            switch self {
            case .library: "gamecontroller.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    let model: AppModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSection: Section? = .library

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task {
            await model.loadLibraryIfNeeded()
        }
    }

    private var compactLayout: some View {
        TabView {
            NavigationStack {
                LibraryView(model: model)
            }
            .tabItem {
                Label(Section.library.titleKey, systemImage: Section.library.symbolName)
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(Section.settings.titleKey, systemImage: Section.settings.symbolName)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.titleKey, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle("app.name")
        } detail: {
            NavigationStack {
                switch selectedSection ?? .library {
                case .library:
                    LibraryView(model: model)
                case .settings:
                    SettingsView()
                }
            }
        }
    }
}
