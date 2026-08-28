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

                #if DEBUG
                NavigationLink {
                    DeveloperDiagnosticsView(model: model)
                } label: {
                    Label("diagnostics.dev.title", systemImage: "ladybug")
                }
                #endif

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

    private var installedByteCount: Int64 {
        model.games.reduce(0) { partial, game in
            let addition = partial.addingReportingOverflow(game.installedByteCount)
            return addition.overflow ? Int64.max : addition.partialValue
        }
    }

    var body: some View {
        List {
            Section("storage.summary.title") {
                LabeledContent("storage.summary.games", value: model.games.count.formatted())
                LabeledContent("storage.summary.installed") {
                    Text(installedByteCount, format: .byteCount(style: .file))
                }
            }

            Section {
                Text("storage.summary.message")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.storage")
        .toolbar {
            Button("common.refresh") {
                Task { await model.reloadLibrary() }
            }
        }
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
        }
    }
}

private struct LicensesView: View {
    private struct Notice: Identifiable {
        let id: String
        let name: String
        let license: String
        let url: String?
    }

    private let bundledNotices: [Notice] = [
        Notice(id: "yume", name: "Yume", license: "GPL-3.0-or-later", url: nil),
        Notice(id: "zlib", name: "zlib (via system libz)", license: "zlib", url: "https://www.zlib.net/zlib_license.html"),
        Notice(id: "mkxp-z", name: "mkxp-z / Empo mobile fork", license: "GPL-2.0-or-later", url: "https://github.com/mateo-m/mkxp-z-apple-mobile"),
        Notice(id: "aetherkiri", name: "AetherKiri 0.5 / OnscripterYuri", license: "GPL-3.0-or-later / GPL-2.0-or-later", url: "https://github.com/AetherKiri/AetherKiri"),
        Notice(id: "renpy", name: "Ren'Py 8.5.3 / 7.8.7 and Renios", license: "MIT AND LGPL-2.1-or-later AND Python-2.0", url: "https://github.com/renpy/renpy"),
        Notice(id: "ruffle", name: "Ruffle 0.5.0", license: "Apache-2.0 OR MIT", url: "https://github.com/ruffle-rs/ruffle"),
        Notice(id: "plzma", name: "PLzmaSDK / LZMA SDK", license: "MIT AND public-domain", url: "https://github.com/OlehKulykov/PLzmaSDK"),
        Notice(id: "minizip", name: "minizip-ng", license: "zlib", url: "https://github.com/zlib-ng/minizip-ng")
    ]

    var body: some View {
        List {
            Section("licenses.app.title") {
                Text("licenses.app.message")
            }
            Section("licenses.thirdparty.title") {
                ForEach(bundledNotices.indices, id: \.self) { index in
                    let notice: Notice = bundledNotices[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.name)
                            .font(.subheadline.weight(.medium))
                        Text(notice.license)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = notice.url, let link = URL(string: url) {
                            Link(url.absoluteString, destination: link)
                                .font(.caption2)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            Section("licenses.system.title") {
                Text("licenses.system.message")
            }
        }
        .navigationTitle("settings.licenses")
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
