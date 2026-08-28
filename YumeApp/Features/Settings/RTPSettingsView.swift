import SwiftUI
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct RTPSettingsView: View {
    let model: AppModel

    @State private var presentsEngineMenu = false
    @State private var presentsImporter = false
    @State private var selectedEngine: GameEngineCatalogEntry?
    @State private var removalCandidate: RTPPackage?
    @State private var operationFailed = false

    private var sortedPackages: [RTPPackage] {
        model.rtpPackages.sorted { $0.engineID.rawValue < $1.engineID.rawValue }
    }

    var body: some View {
        Group {
            if sortedPackages.isEmpty {
                ContentUnavailableView {
                    Label("rtp.empty.title", systemImage: "shippingbox")
                } description: {
                    Text("rtp.empty.message")
                } actions: {
                    Button("rtp.import.action") { presentsEngineMenu = true }
                }
                .buttonStyle(.borderedProminent)
            } else {
                packageList
            }
        }
        .navigationTitle("settings.rtp")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentsEngineMenu = true
                } label: {
                    Label("rtp.import.action", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "rtp.import.menu.title",
            isPresented: $presentsEngineMenu,
            titleVisibility: .visible
        ) {
            ForEach(model.engineCatalog.entries) { entry in
                Button(entry.descriptor.displayName) {
                    selectedEngine = entry
                    presentsImporter = true
                }
            }
        } message: {
            Text("rtp.import.menu.message")
        }
        .fileImporter(
            isPresented: $presentsImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            defer { selectedEngine = nil }
            guard case let .success(urls) = result, let url = urls.first,
                  let engine = selectedEngine
            else { return }
            let rawName = url.deletingPathExtension().lastPathComponent
            let name = sanitize(rawName)
            guard !name.isEmpty, name == rawName, RTPPackage.isValidName(name) else {
                operationFailed = true
                return
            }
            Task {
                let imported = await model.importRTPPackage(named: name, engine: engine.descriptor.id, from: url)
                if !imported { operationFailed = true }
            }
        }
        .alert("rtp.error.title", isPresented: $operationFailed) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("rtp.error.message")
        }
        .alert(
            "rtp.delete.confirm.title",
            isPresented: removalBinding
        ) {
            Button("common.cancel", role: .cancel) {}
            Button("game.delete", role: .destructive) {
                if let candidate = removalCandidate {
                    Task {
                        if !(await model.removeRTPPackage(candidate)) {
                            operationFailed = true
                        }
                    }
                }
            }
        } message: {
            Text("rtp.delete.confirm.message")
        }
    }

    private var packageList: some View {
        List {
            Section {
                Text("rtp.message")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(sortedPackages) { package in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.id)
                            .font(.subheadline.weight(.medium))
                        Text(package.engineID.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(package.byteCount, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        removalCandidate = package
                    } label: {
                        Label("game.delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { presented in
                if !presented {
                    removalCandidate = nil
                }
            }
        )
    }

    private func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }.prefix(64))
    }
}
