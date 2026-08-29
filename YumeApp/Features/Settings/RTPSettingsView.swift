import SwiftUI
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct RTPSettingsView: View {
    let model: AppModel

    @State private var presentsEngineMenu = false
    @State private var presentsImporter = false
    @State private var selectedVariant: RPGMakerRTPVariant?
    @State private var removalCandidate: RTPPackage?
    @State private var operationError: RTPStoreError?

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
            ForEach(RPGMakerRTPVariant.allCases, id: \.self) { variant in
                Button(variant.localizedNameKey) {
                    selectedVariant = variant
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
            defer { selectedVariant = nil }
            guard case let .success(urls) = result, let url = urls.first,
                  let variant = selectedVariant
            else {
                if case .failure = result { operationError = .sourceUnreadable }
                return
            }
            Task {
                operationError = await model.importRPGMakerRTP(variant: variant, from: url)
            }
        }
        .alert("rtp.error.title", isPresented: operationErrorBinding) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(operationError?.localizedMessageKey ?? "rtp.error.unknown")
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
                            operationError = .copyFailed
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
                        if let variant = package.variant {
                            Text(variant.localizedNameKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { presented in
                if !presented { operationError = nil }
            }
        )
    }
}

private extension RPGMakerRTPVariant {
    var localizedNameKey: LocalizedStringKey {
        switch self {
        case .xp: "rtp.variant.xp"
        case .vx: "rtp.variant.vx"
        case .vxAce: "rtp.variant.vxAce"
        }
    }
}

private extension RTPStoreError {
    var localizedMessageKey: LocalizedStringKey {
        switch self {
        case .duplicateName, .duplicateVariant: "rtp.error.duplicate"
        case .sourceIsNotDirectory: "rtp.error.notDirectory"
        case .sourceIsEmpty: "rtp.error.empty"
        case .invalidRPGMakerLayout: "rtp.error.layout"
        case .ambiguousRPGMakerLayout: "rtp.error.ambiguous"
        case .sourceUnreadable: "rtp.error.unreadable"
        case .copyFailed: "rtp.error.copy"
        case .invalidName, .packageNotFound, .corruptIndex: "rtp.error.unknown"
        }
    }
}
