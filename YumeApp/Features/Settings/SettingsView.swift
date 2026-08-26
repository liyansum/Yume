import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("settings.section.library") {
                SettingsRow(title: "settings.storage", systemImage: "internaldrive")
                SettingsRow(title: "settings.controls", systemImage: "gamecontroller")
                SettingsRow(title: "settings.compatibility", systemImage: "checkmark.seal")
            }

            Section("settings.section.support") {
                SettingsRow(title: "settings.diagnostics", systemImage: "waveform.path.ecg")
                SettingsRow(title: "settings.licenses", systemImage: "doc.text")
                SettingsRow(title: "settings.privacy", systemImage: "hand.raised")
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

private struct SettingsRow: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .accessibilityHint("settings.comingSoon")
    }
}

private struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("app.name")
                        .font(.title2.bold())
                    Text("about.developmentBuild")
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
