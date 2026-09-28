import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import IOKit

struct RexQuota {
    var session: Double?
    var week: Double?
    var sessionReset: Date?
    var weekReset: Date?
    var plan: String?
    var status = "Loading…"
}

@MainActor
final class RexDashboardData: ObservableObject {
    static let shared = RexDashboardData()

    @Published private(set) var claude = RexQuota()
    @Published private(set) var codex = RexQuota()
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var cpu: Double?
    @Published private(set) var gpu: Double?
    @Published private(set) var ram: Double?

    private var previousCPU: (busy: UInt64, total: UInt64)?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private init() {
        sampleMetrics()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleMetrics() }
        }
        Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshUsage() }
        }
        refreshUsage()
    }

    func refreshUsage() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshingUsage = true
        refreshTask = Task {
            async let claudeValue = Self.fetchClaude()
            async let codexValue = Self.fetchCodex()
            let (newClaude, newCodex) = await (claudeValue, codexValue)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            claude = newClaude
            codex = newCodex
            isRefreshingUsage = false
        }
    }

    private func sampleMetrics() {
        cpu = readCPU() ?? cpu
        gpu = readGPU()
        ram = readRAM()
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)
        defer { previousCPU = (busy, total) }
        guard let previousCPU, total > previousCPU.total else { return nil }
        return min(1, Double(busy - previousCPU.busy) / Double(total - previousCPU.total))
    }

    private func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let usage = statistics["Device Utilization %"] as? Int else { continue }
            return Double(max(0, min(100, usage))) / 100
        }
        return nil
    }

    private func readRAM() -> Double? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let appPages = max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count))
        let usedPages = appPages + Int64(info.wire_count) + Int64(info.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? max(0, min(1, Double(usedPages) * Double(vm_kernel_page_size) / total)) : nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, "") }
    }

    private static func webRequest(_ url: String, headers: [String: String], body: [String: String]? = nil) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func fetchClaude() async -> RexQuota {
        let keychain = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        guard keychain.0 == 0, let data = keychain.1.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return RexQuota(status: "Sign in to Claude Code")
        }
        var token = oauth["accessToken"] as? String ?? ""
        let expiry = (oauth["expiresAt"] as? Double ?? 0) / 1000
        if token.isEmpty || expiry < Date().timeIntervalSince1970 + 90 {
            guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
                return RexQuota(status: "Claude login expired")
            }
            let fingerprint = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
            let lastFailure = UserDefaults.standard.double(forKey: "rexnotch.claudeRefreshFailedAt")
            guard UserDefaults.standard.string(forKey: "rexnotch.deadClaudeRefresh") != fingerprint
                    || Date().timeIntervalSince1970 - lastFailure > 900 else {
                return RexQuota(status: "Claude login expired")
            }
            let refreshed = await webRequest("https://api.anthropic.com/v1/oauth/token",
                                             headers: ["Accept": "application/json", "User-Agent": "claude-code/2.0"],
                                             body: ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                                    "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
            guard let refreshed, let newToken = refreshed["access_token"] as? String else {
                UserDefaults.standard.set(fingerprint, forKey: "rexnotch.deadClaudeRefresh")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "rexnotch.claudeRefreshFailedAt")
                return RexQuota(status: "Claude login expired")
            }
            token = newToken
            oauth["accessToken"] = newToken
            if let newRefresh = refreshed["refresh_token"] as? String { oauth["refreshToken"] = newRefresh }
            oauth["expiresAt"] = (Date().timeIntervalSince1970 + (refreshed["expires_in"] as? Double ?? 28800)) * 1000
            root["claudeAiOauth"] = oauth
            if let output = try? JSONSerialization.data(withJSONObject: root),
               let string = String(data: output, encoding: .utf8) {
                let saved = run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(),
                                                       "-s", "Claude Code-credentials", "-w", string])
                if saved.0 != 0 { return RexQuota(status: "Keychain update failed") }
            }
            UserDefaults.standard.removeObject(forKey: "rexnotch.deadClaudeRefresh")
            UserDefaults.standard.removeObject(forKey: "rexnotch.claudeRefreshFailedAt")
        }
        guard let json = await webRequest("https://api.anthropic.com/api/oauth/usage",
                                           headers: ["Authorization": "Bearer \(token)", "Accept": "application/json",
                                                     "anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01",
                                                     "User-Agent": "claude-code/2.0"]) else {
            return RexQuota(status: "Claude usage unavailable")
        }
        let session = json["five_hour"] as? [String: Any] ?? [:]
        let week = json["seven_day"] as? [String: Any] ?? [:]
        return RexQuota(session: session["utilization"] as? Double, week: week["utilization"] as? Double,
                        sessionReset: date(session["resets_at"]), weekReset: date(week["resets_at"]),
                        plan: oauth["subscriptionType"] as? String, status: "Live")
    }

    private static func jwtExpiry(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["exp"] as? Double
    }

    private static func fetchCodex() async -> RexQuota {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String,
              var token = tokens["access_token"] as? String else {
            return RexQuota(status: "Sign in to Codex")
        }
        if (jwtExpiry(token) ?? 0) < Date().timeIntervalSince1970 + 90 {
            guard let refresh = tokens["refresh_token"] as? String else { return RexQuota(status: "Codex login expired") }
            guard let refreshed = await webRequest("https://auth.openai.com/oauth/token",
                                                    headers: ["Accept": "application/json"],
                                                    body: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                           "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"]),
                  let newToken = refreshed["access_token"] as? String else {
                return RexQuota(status: "Codex login expired")
            }
            token = newToken
            tokens["access_token"] = newToken
            if let newRefresh = refreshed["refresh_token"] as? String { tokens["refresh_token"] = newRefresh }
            if let idToken = refreshed["id_token"] as? String { tokens["id_token"] = idToken }
            root["tokens"] = tokens
            root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            guard let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]),
                  (try? output.write(to: url, options: .atomic)) != nil else {
                return RexQuota(status: "Codex login update failed")
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let json = await webRequest("https://chatgpt.com/backend-api/wham/usage",
                                           headers: ["Authorization": "Bearer \(token)", "chatgpt-account-id": account,
                                                     "originator": "codex_cli_rs", "Accept": "application/json",
                                                     "User-Agent": "codex_cli_rs/0.20.0"]),
              let limit = json["rate_limit"] as? [String: Any] else {
            return RexQuota(status: "Codex usage unavailable")
        }
        let session = limit["primary_window"] as? [String: Any] ?? [:]
        let week = limit["secondary_window"] as? [String: Any] ?? [:]
        return RexQuota(session: session["used_percent"] as? Double, week: week["used_percent"] as? Double,
                        sessionReset: (session["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                        weekReset: (week["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                        plan: json["plan_type"] as? String, status: "Live")
    }
}
