import SwiftUI
import YumeApplication
import YumeDomain

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("settings.section.library") {
                NavigationLink {
                    StorageSettingsView(model: model)
                } label: {
                    Label("settings.storage", systemImage: "internaldrive")
                }

                NavigationLink {
                    RTPSettingsView(model: model)
                } label: {
                    Label("settings.rtp", systemImage: "shippingbox")
                }

                NavigationLink {
                    ControlSettingsView()
                } label: {
                    Label("settings.controls", systemImage: "gamecontroller")
                }

                NavigationLink {
                    CompatibilitySettingsView(catalog: model.engineCatalog)
                } label: {
                    Label("settings.compatibility", systemImage: "checkmark.seal")
                }
            }

            Section("settings.section.support") {
                NavigationLink {
                    DiagnosticsView(model: model)
                } label: {
                    Label("settings.diagnostics", systemImage: "waveform.path.ecg")
                }

                NavigationLink {
                    DeveloperDiagnosticsView(model: model)
                } label: {
                    Label("diagnostics.dev.title", systemImage: "ladybug")
                }

                NavigationLink {
                    LicensesView()
                } label: {
                    Label("settings.licenses", systemImage: "doc.text")
                }

                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("settings.privacy", systemImage: "hand.raised")
                }
            }

            Section("settings.section.about") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("settings.about", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("settings.title")
    }
}

private struct StorageSettingsView: View {
    let model: AppModel

    @State private var pendingGameDeletion: ImportedGame?
    @State private var pendingSaveDeletion: GameSaveLibrary?
    @State private var operationFailed = false

    private var installedByteCount: Int64 {
        model.games.reduce(0) { partial, game in
            let addition = partial.addingReportingOverflow(game.installedByteCount)
            return addition.overflow ? Int64.max : addition.partialValue
        }
    }

    private var saveByteCount: Int64 {
        model.saveLibraries.reduce(0) { partial, library in
            let result = partial.addingReportingOverflow(library.byteCount)
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    var body: some View {
        List {
            Section("storage.summary.title") {
                LabeledContent("storage.summary.games", value: model.games.count.formatted())
                LabeledContent("storage.summary.installed") {
                    Text(installedByteCount, format: .byteCount(style: .file))
                }
                LabeledContent("storage.summary.saves") {
                    Text(saveByteCount, format: .byteCount(style: .file))
                }
            }

            Section("storage.games.title") {
                if model.games.isEmpty {
                    Text("storage.games.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.games) { game in
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(game.title)
                                Text(game.engine.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(game.installedByteCount, format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                pendingGameDeletion = game
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("game.delete"))
                        }
                    }
                }
            }

            Section("storage.saves.title") {
                if model.saveLibraries.isEmpty {
                    Text("storage.saves.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.saveLibraries) { library in
                        HStack(spacing: 12) {
                            Image(systemName: library.boundGameID == nil ? "archivebox" : "link.circle.fill")
                                .foregroundStyle(
                                    library.boundGameID == nil ? Color.secondary : Color.accentColor
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(library.title)
                                Text(saveBindingDescription(library))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(library.byteCount, format: .byteCount(style: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                pendingSaveDeletion = library
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("storage.saves.delete"))
                        }
                    }
                }
            } footer: {
                Text("storage.saves.message")
            }
        }
        .navigationTitle("settings.storage")
        .task { await model.refreshSaveLibraries() }
        .toolbar {
            Button("common.refresh") {
                Task {
                    await model.reloadLibrary()
                    await model.refreshSaveLibraries()
                }
            }
        }
        .confirmationDialog(
            "storage.games.delete.title",
            isPresented: pendingGameDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("storage.games.delete.confirm", role: .destructive) {
                guard let game = pendingGameDeletion else { return }
                pendingGameDeletion = nil
                Task {
                    operationFailed = !(await model.remove(game, policy: .preserveSaves))
                }
            }
            Button("common.cancel", role: .cancel) { pendingGameDeletion = nil }
        } message: {
            Text("storage.games.delete.message")
        }
        .confirmationDialog(
            "storage.saves.delete.title",
            isPresented: pendingSaveDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("storage.saves.delete.confirm", role: .destructive) {
                guard let library = pendingSaveDeletion else { return }
                pendingSaveDeletion = nil
                Task {
                    operationFailed = !(await model.deleteSaveLibrary(library))
                }
            }
            Button("common.cancel", role: .cancel) { pendingSaveDeletion = nil }
        } message: {
            Text(saveDeletionMessage)
        }
        .alert("storage.operation.error.title", isPresented: $operationFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("storage.operation.error.message")
        }
    }

    private func saveBindingDescription(_ library: GameSaveLibrary) -> String {
        guard let gameID = library.boundGameID,
              let game = model.games.first(where: { $0.id == gameID })
        else { return String(localized: "storage.saves.unbound") }
        return String.localizedStringWithFormat(
            String(localized: "storage.saves.bound"),
            game.title
        )
    }

    private var pendingGameDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingGameDeletion != nil },
            set: { if !$0 { pendingGameDeletion = nil } }
        )
    }

    private var pendingSaveDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingSaveDeletion != nil },
            set: { if !$0 { pendingSaveDeletion = nil } }
        )
    }

    private var saveDeletionMessage: LocalizedStringKey {
        pendingSaveDeletion?.boundGameID == nil
            ? "storage.saves.delete.message"
            : "storage.saves.delete.bound.message"
    }
}

private struct ControlSettingsView: View {
    @AppStorage("controls.virtual.enabled") private var virtualControlsEnabled = true
    @AppStorage("controls.haptics.enabled") private var hapticsEnabled = true
    @AppStorage("controls.orientation") private var orientation = "automatic"

    var body: some View {
        Form {
            Section("controls.input.title") {
                Toggle("controls.virtual", isOn: $virtualControlsEnabled)
                Toggle("controls.haptics", isOn: $hapticsEnabled)
            }

            Section("controls.orientation.title") {
                Picker("controls.orientation.choice", selection: $orientation) {
                    Text("controls.orientation.automatic").tag("automatic")
                    Text("controls.orientation.landscape").tag("landscape")
                    Text("controls.orientation.portrait").tag("portrait")
                }
            }
        }
        .navigationTitle("settings.controls")
    }
}

private struct CompatibilitySettingsView: View {
    let catalog: GameEngineCatalog

    var body: some View {
        List {
            ForEach(catalog.entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.descriptor.displayName)
                        Text(entry.descriptor.compatibilityVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        hostingLabel(for: entry.hostingKind),
                        systemImage: hostingSymbol(for: entry.hostingKind)
                    )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(hostingTint(for: entry.hostingKind))
                    .accessibilityLabel(Text(hostingLabel(for: entry.hostingKind)))
                }
                .accessibilityElement(children: .combine)
            }

            Section {
                Text("compatibility.runtime.message")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.compatibility")
    }

    private func hostingLabel(for kind: EngineHostingKind) -> LocalizedStringKey {
        switch kind {
        case .restrictedWeb: "compatibility.runtime.available"
        case .dedicatedRuntime: "compatibility.runtime.dedicated"
        case .detectionOnly: "compatibility.runtime.detectionOnly"
        }
    }

    private func hostingSymbol(for kind: EngineHostingKind) -> String {
        switch kind {
        case .restrictedWeb: "checkmark.circle.fill"
        case .dedicatedRuntime: "shippingbox.circle.fill"
        case .detectionOnly: "magnifyingglass.circle"
        }
    }

    private func hostingTint(for kind: EngineHostingKind) -> Color {
        switch kind {
        case .restrictedWeb: .green
        case .dedicatedRuntime: .blue
        case .detectionOnly: .orange
        }
    }
}

private struct DiagnosticsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("diagnostics.library.title") {
                LabeledContent("diagnostics.library.loaded", value: model.libraryLoadFailed ? "No" : "Yes")
                LabeledContent("diagnostics.library.games", value: model.games.count.formatted())
                LabeledContent("diagnostics.recovery.issues", value: model.recoveryIssueCount.formatted())
                LabeledContent("diagnostics.entries", value: model.diagnosticEntryCount.formatted())
            }

            Section("appLogs.title") {
                NavigationLink {
                    AppLogsView(model: model)
                } label: {
                    Label("appLogs.open", systemImage: "doc.text.magnifyingglass")
                }
                LabeledContent("appLogs.count", value: model.appLogs.count.formatted())
            }

            Section("diagnostics.export.title") {
                Button("diagnostics.export.prepare") {
                    Task { await model.prepareDiagnosticExport() }
                }
                if let exportURL = model.diagnosticExportURL {
                    ShareLink("diagnostics.export.share", item: exportURL)
                }
            }

            Section {
                Text("diagnostics.offline.message")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.diagnostics")
        .task {
            await model.refreshDiagnostics()
            await model.refreshAppLogs()
        }
    }
}

private struct LicensesView: View {
    var body: some View {
        List {
            Section("licenses.app.title") {
                Text("licenses.app.message")
            }
            Section("licenses.thirdparty.title") {
                noticeRow("Yume", license: "GPL-3.0-or-later")
                noticeRow("zlib (via system libz)", license: "zlib", url: "https://www.zlib.net/zlib_license.html")
                noticeRow("mkxp-z / Empo mobile fork", license: "GPL-2.0-or-later", url: "https://github.com/mateo-m/mkxp-z-apple-mobile")
                noticeRow("AetherKiri 0.5 / OnscripterYuri", license: "GPL-3.0-or-later / GPL-2.0-or-later", url: "https://github.com/AetherKiri/AetherKiri")
                noticeRow("Ren'Py 8.5.3 / 7.8.7 and Renios", license: "MIT AND LGPL-2.1-or-later AND Python-2.0", url: "https://github.com/renpy/renpy")
                noticeRow("Ruffle 0.5.0", license: "Apache-2.0 OR MIT", url: "https://github.com/ruffle-rs/ruffle")
                noticeRow("PLzmaSDK / LZMA SDK", license: "MIT AND public-domain", url: "https://github.com/OlehKulykov/PLzmaSDK")
                noticeRow("minizip-ng", license: "zlib", url: "https://github.com/zlib-ng/minizip-ng")
            }
            Section("licenses.system.title") {
                Text("licenses.system.message")
            }
        }
        .navigationTitle("settings.licenses")
    }

    private func noticeRow(_ name: String, license: String, url: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline.weight(.medium))
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url, let link = URL(string: url) {
                Link(url, destination: link)
                    .font(.caption2)
            }
        }
        .frame(minHeight: 44)
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            Section("privacy.offline.title") {
                Text("privacy.offline.message")
            }
            Section("privacy.files.title") {
                Text("privacy.files.message")
            }
            Section("privacy.telemetry.title") {
                Text("privacy.telemetry.message")
            }
        }
        .navigationTitle("settings.privacy")
    }
}

private struct AboutView: View {
    private var version: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(shortVersion) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("app.name")
                        .font(.title2.bold())
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            Section("about.offline.title") {
                Text("about.offline.message")
            }

            Section("about.importRights.title") {
                Text("about.importRights.message")
            }
        }
        .navigationTitle("settings.about")
        .navigationBarTitleDisplayMode(.inline)
    }
}
