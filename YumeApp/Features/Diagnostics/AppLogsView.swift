import SwiftUI
import YumeInfrastructure

struct AppLogsView: View {
    let model: AppModel

    @State private var confirmsDeleteAll = false
    @State private var deleteFailed = false

    var body: some View {
        List {
            Section {
                Toggle(
                    "appLogs.autoCleanup",
                    isOn: Binding(
                        get: { model.appLogAutoCleanupEnabled },
                        set: { enabled in
                            Task { await model.setAppLogAutoCleanupEnabled(enabled) }
                        }
                    )
                )
                Text("appLogs.autoCleanup.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("appLogs.sessions.title") {
                if model.appLogs.isEmpty {
                    Text("appLogs.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.appLogs) { log in
                        ShareLink(item: log.url) {
                            HStack(spacing: 12) {
                                Image(systemName: log.isCurrent ? "record.circle" : "doc.text")
                                    .foregroundStyle(log.isCurrent ? Color.red : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(log.startedAt.formatted(date: .abbreviated, time: .standard))
                                    Text(log.byteCount, format: .byteCount(style: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if log.isCurrent {
                                    Text("appLogs.current")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }

            Section {
                if model.runtimeLogs.isEmpty {
                    Text("appLogs.runtime.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.runtimeLogs) { log in
                        ShareLink(item: log.url) {
                            HStack(spacing: 12) {
                                Image(systemName: "gearshape.2")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(log.url.lastPathComponent)
                                    Text("\(log.gameTitle) · \(log.engineName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(log.byteCount, format: .byteCount(style: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            } header: {
                Text("appLogs.runtime.title")
            } footer: {
                Text("appLogs.runtime.description")
            }

            Section {
                Button("appLogs.export.prepare") {
                    Task { await model.prepareAppLogExport() }
                }
                if let exportURL = model.appLogExportURL {
                    ShareLink("appLogs.export.share", item: exportURL)
                }
            } header: {
                Text("appLogs.export.title")
            } footer: {
                Text("appLogs.export.description")
            }

            Section {
                Button("appLogs.deleteAll", role: .destructive) {
                    confirmsDeleteAll = true
                }
            } footer: {
                Text("appLogs.deleteAll.description")
            }
        }
        .navigationTitle("appLogs.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.startAppLoggingIfNeeded()
            await model.refreshAppLogs()
        }
        .confirmationDialog(
            "appLogs.delete.confirm.title",
            isPresented: $confirmsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("appLogs.deleteAll", role: .destructive) {
                Task {
                    deleteFailed = !(await model.removeAllAppLogs())
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("appLogs.delete.confirm.message")
        }
        .alert("appLogs.delete.error.title", isPresented: $deleteFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("appLogs.delete.error.message")
        }
    }
}
