import AppKit
import Combine
import Foundation
import SwiftUI

enum RexPowerMode: String, CaseIterable {
    case normal
    case batterySaver
    case keepAwake

    var title: String {
        switch self {
        case .normal: "Normal"
        case .batterySaver: "Battery Saver"
        case .keepAwake: "Keep Awake"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "power"
        case .batterySaver: "leaf"
        case .keepAwake: "moon.zzz.fill"
        }
    }

    var next: Self {
        switch self {
        case .normal: .batterySaver
        case .batterySaver: .keepAwake
        case .keepAwake: .normal
        }
    }
}

@MainActor
final class RexSystemControls: ObservableObject {
    static let shared = RexSystemControls()

    @Published private(set) var mode: RexPowerMode
    @Published private(set) var isChangingPower = false
    @Published var errorMessage: String?

    private init() {
        mode = RexPowerMode(rawValue: UserDefaults.standard.string(forKey: "rexnotch.powerMode") ?? "") ?? .normal
    }

    func cyclePower() {
        guard !isChangingPower else { return }
        let next = mode.next
        isChangingPower = true
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                Self.applyPower(next)
            }.value
            isChangingPower = false
            if succeeded {
                mode = next
                UserDefaults.standard.set(next.rawValue, forKey: "rexnotch.powerMode")
            } else {
                errorMessage = "The power mode was not changed. macOS administrator approval is required."
            }
        }
    }

    private nonisolated static func applyPower(_ mode: RexPowerMode) -> Bool {
        let command: String
        switch mode {
        case .normal:
            command = "/usr/bin/pmset disablesleep 0; /usr/bin/pmset -a lowpowermode 0"
        case .batterySaver:
            command = "/usr/bin/pmset disablesleep 0; /usr/bin/pmset -a lowpowermode 1"
        case .keepAwake:
            // disablesleep is needed for closed-lid operation; an idle-sleep
            // assertion alone stops working when the MacBook lid is closed.
            command = "/usr/bin/pmset -a lowpowermode 0; /usr/bin/pmset disablesleep 1"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"set -e; \(command)\" with administrator privileges"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func startUpdateAll() {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RexNotch", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let script = support.appendingPathComponent("update-all.command")
            try Self.updateScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", script.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                errorMessage = "Terminal could not start the update."
            }
        } catch {
            errorMessage = "The update command could not be opened."
        }
    }

    private static let updateScript = """
    #!/bin/zsh
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    failed=0
    run_step() {
      echo ""
      echo "== $1 =="
      shift
      "$@" || failed=1
    }
    if ! command -v brew >/dev/null 2>&1; then
      echo "Homebrew is not installed."
      exit 1
    fi
    run_step "Updating Homebrew" brew update
    run_step "Updating Homebrew formulae" brew upgrade --formula --yes
    run_step "Updating Homebrew apps" brew upgrade --cask --greedy --yes
    if ! command -v mas >/dev/null 2>&1; then
      run_step "Installing Mac App Store updater" brew install mas
    fi
    if command -v mas >/dev/null 2>&1; then
      run_step "Updating Mac App Store apps" mas update
    else
      echo "Mac App Store apps could not be updated because mas is unavailable."
      failed=1
    fi
    echo ""
    if [[ $failed -eq 0 ]]; then
      echo "All available Homebrew and Mac App Store app updates finished."
    else
      echo "Some updates did not finish. Review the messages above."
    fi
    echo "Press Return to close this window."
    read -r
    """
}

struct RexControlsSettingsView: View {
    @ObservedObject private var controls = RexSystemControls.shared

    var body: some View {
        Form {
            Section("Power") {
                Button {
                    controls.cyclePower()
                } label: {
                    Label(controls.mode.title, systemImage: controls.mode.symbol)
                }
                .disabled(controls.isChangingPower)
                Text("Each click cycles Normal → Battery Saver → Keep Awake. Keep Awake also prevents sleep with the lid closed. The selected mode changes only when you click, and macOS asks for administrator approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Button("Update All") { controls.startUpdateAll() }
                Text("Opens Terminal to update Homebrew formulae and apps, then Mac App Store apps. Updates start only when you click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Controls")
        .alert("RexNotch", isPresented: Binding(
            get: { controls.errorMessage != nil },
            set: { if !$0 { controls.errorMessage = nil } }
        )) {
            Button("OK") { controls.errorMessage = nil }
        } message: {
            Text(controls.errorMessage ?? "")
        }
    }
}
