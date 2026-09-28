import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        Form {
            Section("RexNotch") {
                LabeledContent("Version", value: Bundle.main.releaseVersionNumber ?? "Development build")
                Text("A personal fork of Boring Notch, distributed under GPL-3.0-or-later.")
                    .foregroundStyle(.secondary)
            }

            Section("Source") {
                Button("RexNotch on GitHub") {
                    open("https://github.com/rexmhall09/rexnotch")
                }
                Button("Original Boring Notch project") {
                    open("https://github.com/TheBoredTeam/boring.notch")
                }
            }
        }
        .navigationTitle("About")
    }

    private func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}
