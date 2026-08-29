import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YumeApplication
import YumeDomain

struct RTPSettingsView: View {
    let model: AppModel

    @State private var presentsImporter = false
    @State private var removalCandidate: RTPPackage?
    @State private var operationError: RTPStoreError?
    @State private var pendingVariantURL: URL?
    @State private var pendingVariantError = false

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
                    Button("rtp.import.action") { presentsImporter = true }
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
                    presentsImporter = true
                } label: {
                    Label("rtp.import.action", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $presentsImporter) {
            CopyingRTPArchivePicker(isPresented: $presentsImporter) { urls in
                importSelectedArchives(urls)
            }
        }
        .alert("rtp.error.title", isPresented: operationErrorBinding) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(operationError?.localizedMessageKey ?? "rtp.error.unknown")
        }
        .confirmationDialog(
            "rtp.variant.choose.title",
            isPresented: $pendingVariantError,
            titleVisibility: .visible
        ) {
            ForEach(RPGMakerRTPVariant.allCases, id: \.self) { variant in
                Button(variant.localizedNameKey) {
                    guard let url = pendingVariantURL else { return }
                    pendingVariantURL = nil
                    Task {
                        defer { try? FileManager.default.removeItem(at: url) }
                        operationError = await model.importRPGMakerRTP(
                            from: url,
                            variantHint: variant
                        )
                    }
                }
            }
            Button("common.cancel", role: .cancel) {
                if let url = pendingVariantURL {
                    try? FileManager.default.removeItem(at: url)
                }
                pendingVariantURL = nil
            }
        } message: {
            Text("rtp.variant.choose.message")
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
                        if let variant = package.variant {
                            Text(variant.localizedNameKey)
                                .font(.subheadline.weight(.medium))
                        } else {
                            Text(package.id)
                                .font(.subheadline.weight(.medium))
                        }
                        Text("RPG Maker RTP")
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

    private func importSelectedArchives(_ urls: [URL]) {
        Task {
            var firstError: RTPStoreError?
            for url in urls {
                if let error = await model.importRPGMakerRTP(from: url) {
                    if error == .unidentifiedRPGMakerVariant, pendingVariantURL == nil {
                        pendingVariantURL = url
                        pendingVariantError = true
                        continue
                    }
                    try? FileManager.default.removeItem(at: url)
                    if firstError == nil { firstError = error }
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            operationError = firstError
        }
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

/// File copies work reliably in LiveContainer, unlike provider-backed folder
/// URLs. One ZIP may contain XP, VX and VXAce wrappers and imports all three.
private struct CopyingRTPArchivePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.zip]
        if let sevenZip = UTType(filenameExtension: "7z") { types.append(sevenZip) }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: CopyingRTPArchivePicker

        init(parent: CopyingRTPArchivePicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            if !urls.isEmpty { parent.onPick(urls) }
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
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
        case .sourceIsNotZIPArchive: "rtp.error.notArchive"
        case .invalidZIPArchive: "rtp.error.invalidArchive"
        case .unidentifiedRPGMakerVariant: "rtp.error.variant"
        case .copyFailed: "rtp.error.copy"
        case .invalidName, .packageNotFound, .corruptIndex: "rtp.error.unknown"
        }
    }
}
