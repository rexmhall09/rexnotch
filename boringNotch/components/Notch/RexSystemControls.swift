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
    @Published private(set) var powerControlReady = false
    @Published private(set) var isSettingUpPower = false
    @Published private(set) var isUpdating = false
    @Published private(set) var updateStatus = ""
    @Published var errorMessage: String?

    private init() {
        mode = RexPowerMode(rawValue: UserDefaults.standard.string(forKey: "rexnotch.powerMode") ?? "") ?? .normal
        Task.detached { [weak self] in
            let ready = Self.canSetPowerWithoutPassword()
            await MainActor.run { self?.powerControlReady = ready }
        }
    }

    func cyclePower() {
        guard !isChangingPower else { return }
        guard powerControlReady else {
            errorMessage = "Enable password-free power controls once in Settings → Controls. macOS requires administrator approval to install the restricted power rule."
            return
        }
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
                powerControlReady = false
                errorMessage = "Power mode did not change. Re-enable power controls in Settings → Controls."
            }
        }
    }

    private nonisolated static func applyPower(_ mode: RexPowerMode) -> Bool {
        let commands: [[String]]
        switch mode {
        case .normal:
            commands = [["disablesleep", "0"], ["-a", "lowpowermode", "0"]]
        case .batterySaver:
            commands = [["disablesleep", "0"], ["-a", "lowpowermode", "1"]]
        case .keepAwake:
            commands = [["-a", "lowpowermode", "0"], ["disablesleep", "1"]]
        }
        return commands.allSatisfy { run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + $0) }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                                        output: FileHandle? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    private nonisolated static func canSetPowerWithoutPassword() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"])
            && run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"])
            && run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "lowpowermode", "0"])
            && run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "lowpowermode", "1"])
    }

    func setUpPowerControl() {
        guard !isSettingUpPower else { return }
        isSettingUpPower = true
        Task.detached { [weak self] in
            let success = Self.installPowerRule() && Self.canSetPowerWithoutPassword()
            await MainActor.run {
                self?.isSettingUpPower = false
                self?.powerControlReady = success
                if !success { self?.errorMessage = "Power control setup was cancelled or failed." }
            }
        }
    }

    private nonisolated static func installPowerRule() -> Bool {
        let username = NSUserName()
        guard !username.isEmpty,
              username.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) })
        else { return false }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RexNotch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let source = support.appendingPathComponent("power-sudoers")
            let rule = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1\n"
            try rule.write(to: source, atomically: true, encoding: .utf8)
            let quotedPath = "'" + source.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let destination = "/etc/sudoers.d/rexnotch-power"
            let command = "set -e; /usr/bin/install -o root -g wheel -m 0440 \(quotedPath) \(destination).tmp; /usr/sbin/visudo -cf \(destination).tmp; /bin/mv \(destination).tmp \(destination)"
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let success = run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
            try? FileManager.default.removeItem(at: source)
            return success
        } catch { return false }
    }

    func startUpdateAll() {
        guard !isUpdating else { return }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RexNotch", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let log = support.appendingPathComponent("update-all.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            try handle.truncate(atOffset: 0)
            isUpdating = true
            updateStatus = "Starting updates…"
            Task.detached { [weak self] in
                defer { try? handle.close() }
                let brew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                    ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
                let path = "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = path
                environment["HOMEBREW_NO_SUDO"] = "1"
                environment["NONINTERACTIVE"] = "1"
                guard FileManager.default.fileExists(atPath: brew) else {
                    await MainActor.run {
                        self?.isUpdating = false
                        self?.updateStatus = "Homebrew is not installed"
                    }
                    return
                }
                var failed = false
                let steps: [(String, [String])] = [
                    ("Updating Homebrew", ["update"]),
                    ("Updating formulae", ["upgrade", "--formula", "--yes"]),
                    ("Updating apps", ["upgrade", "--cask", "--greedy", "--yes"])
                ]
                for (title, arguments) in steps {
                    await MainActor.run { self?.updateStatus = title + "…" }
                    handle.write(Data("\n== \(title) ==\n".utf8))
                    if !Self.run(brew, arguments, environment: environment, output: handle) { failed = true }
                }
                let mas = brew.hasPrefix("/opt/") ? "/opt/homebrew/bin/mas" : "/usr/local/bin/mas"
                if !FileManager.default.fileExists(atPath: mas) {
                    await MainActor.run { self?.updateStatus = "Installing App Store updater…" }
                    handle.write(Data("\n== Installing mas ==\n".utf8))
                    if !Self.run(brew, ["install", "mas"], environment: environment, output: handle) { failed = true }
                }
                if FileManager.default.fileExists(atPath: mas) {
                    await MainActor.run { self?.updateStatus = "Updating App Store apps…" }
                    handle.write(Data("\n== Updating Mac App Store apps ==\n".utf8))
                    if !Self.run(mas, ["update"], environment: environment, output: handle) { failed = true }
                } else { failed = true }
                await MainActor.run {
                    self?.isUpdating = false
                    self?.updateStatus = failed ? "Some updates need attention; see Controls" : "All available updates finished"
                }
            }
        } catch {
            errorMessage = "The background update could not start."
        }
    }
}

struct RexControlsSettingsView: View {
    @ObservedObject private var controls = RexSystemControls.shared

    var body: some View {
        Form {
            Section("Power") {
                if !controls.powerControlReady {
                    Button(controls.isSettingUpPower ? "Setting up…" : "Enable password-free power controls") {
                        controls.setUpPowerControl()
                    }
                    .disabled(controls.isSettingUpPower)
                }
                Button {
                    controls.cyclePower()
                } label: {
                    Label(controls.mode.title, systemImage: controls.mode.symbol)
                }
                .disabled(controls.isChangingPower)
                Text("A one-time macOS approval installs a rule limited to four power commands. After setup, each click cycles Normal → Battery Saver → Keep Awake without another password. Keep Awake prevents sleep with the lid closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Button(controls.isUpdating ? "Updating…" : "Update All") { controls.startUpdateAll() }
                    .disabled(controls.isUpdating)
                if !controls.updateStatus.isEmpty { Text(controls.updateStatus) }
                Text("Updates Homebrew formulae, apps, and Mac App Store apps in the background. Apps needing administrator access may be skipped; the log is in Library/Application Support/RexNotch/update-all.log.")
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
