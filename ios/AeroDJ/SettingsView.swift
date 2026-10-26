import SwiftUI

/// Settings and preferences. Uses system components so Dynamic Type and
/// accessibility work for free.
struct SettingsView: View {
    @AppStorage("djChatter") private var djChatter = true
    @AppStorage("spokenBriefing") private var spokenBriefing = true
    @AppStorage("preferredVoice") private var preferredVoice = "Default"

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("DJ chatter between tracks", isOn: $djChatter)
                Toggle("Spoken morning briefing", isOn: $spokenBriefing)
            }

            Section("Voice") {
                Picker("Preferred voice", selection: $preferredVoice) {
                    Text("Default").tag("Default")
                    Text("Calm").tag("Calm")
                    Text("Bright").tag("Bright")
                }
            }

            Section("About") {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Music", value: "Apple Music")
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack { SettingsView() }
}