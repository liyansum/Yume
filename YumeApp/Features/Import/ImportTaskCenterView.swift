import SwiftUI
import YumeDomain

struct ImportTaskCenterView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.recoveredTasks.isEmpty {
                ContentUnavailableView {
                    Label("import.taskCenter.empty.title", systemImage: "tray")
                } description: {
                    Text("import.taskCenter.empty.message")
                }
            } else {
                taskList
            }
        }
        .navigationTitle("import.taskCenter.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("import.taskCenter.dismiss") {
                    model.dismissRecoveredTasks()
                    dismiss()
                }
            }
        }
    }

    private var taskList: some View {
        List {
            Section {
                Text("import.taskCenter.message")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.recoveredTasks, id: \.taskID) { manifest in
                    if let stage = manifest.state.stage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stage.localizedKey)
                                .font(.subheadline.weight(.medium))
                            Text(manifest.updatedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private extension ImportState {
    var stage: ImportStage? {
        switch self {
        case .active(let stage), .paused(let stage):
            stage
        case .cancelled, .failed, .completed:
            nil
        }
    }
}

private extension ImportStage {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .picked: "import.stage.picked"
        case .validatingSource: "import.stage.validatingSource"
        case .budgeting: "import.stage.budgeting"
        case .copyingToStaging: "import.stage.copyingToStaging"
        case .extractingToStaging: "import.stage.extractingToStaging"
        case .detectingRoots: "import.stage.detectingRoots"
        case .resolvingAmbiguity: "import.stage.resolvingAmbiguity"
        case .scanningCompatibility: "import.stage.scanningCompatibility"
        case .awaitingConversionConsent: "import.stage.awaitingConversionConsent"
        case .convertingDerivedData: "import.stage.convertingDerivedData"
        case .validatingCommit: "import.stage.validatingCommit"
        case .committed: "import.stage.committed"
        }
    }
}
