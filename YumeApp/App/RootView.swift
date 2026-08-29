import SwiftUI
import YumeApplication

struct RootView: View {
    enum Section: String, CaseIterable, Hashable, Identifiable {
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
    @Environment(\.scenePhase) private var scenePhase
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
            await model.startAppLoggingIfNeeded()
            await model.loadLibraryIfNeeded()
            await model.refreshRTPPackages()
        }
        .onChange(of: scenePhase) { _, phase in
            let phaseName = switch phase {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
            Task {
                await model.recordAppEvent(
                    "app.scene-phase",
                    metadata: ["phase": phaseName]
                )
            }
            guard phase == .background, model.activeSession != nil else { return }
            model.suspendPlayback()
        }
        .fullScreenCover(item: activeSessionBinding) { session in
            GamePlayerView(
                session: session,
                suspended: model.isPlaybackSuspended,
                onResume: { model.resumePlayback() },
                onClose: { Task { await model.stopPlaying() } },
                onLog: { message, isError, metadata in
                    Task {
                        await model.recordPlayerLog(
                            message,
                            isError: isError,
                            metadata: metadata
                        )
                    }
                }
            )
        }
        .alert("player.error.title", isPresented: playbackFailureBinding) {
            Button("common.ok", role: .cancel) {
                model.dismissPlaybackFailure()
            }
        } message: {
            Text("player.error.message")
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
                SettingsView(model: model)
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
                    SettingsView(model: model)
                }
            }
        }
    }

    private var activeSessionBinding: Binding<GamePlaySession?> {
        Binding(
            get: { model.activeSession },
            set: { newValue in
                if newValue == nil, model.activeSession != nil {
                    Task { await model.stopPlaying() }
                }
            }
        )
    }

    private var playbackFailureBinding: Binding<Bool> {
        Binding(
            get: { model.playbackFailed },
            set: { if !$0 { model.dismissPlaybackFailure() } }
        )
    }
}
