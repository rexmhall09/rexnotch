import Defaults
import SwiftUI

private let rexSurface = Color(red: 0.075, green: 0.082, blue: 0.078)
private let rexMuted = Color.white.opacity(0.53)
private let claudeColor = Color(red: 0.79, green: 0.43, blue: 0.33)
private let codexColor = Color(red: 0.45, green: 0.56, blue: 0.92)

struct RexMetricLabel: View {
    let name: String
    let value: Double?

    var body: some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(rexMuted)
            Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .foregroundStyle(.white)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}

struct RexDashboardView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var data = RexDashboardData.shared
    @ObservedObject private var music = MusicManager.shared
    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @Binding var isHoveringMusicArea: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RexUsageCard(data: data).frame(maxWidth: .infinity)
                CalendarView()
                    .environmentObject(vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .background(rexSurface, in: RoundedRectangle(cornerRadius: 23))
                    .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.08)))
                    .onHover { vm.isHoveringCalendar = $0 }
            }
            .frame(height: 210)

            if music.isPlaying {
                MusicPlayerView(
                    albumArtNamespace: albumArtNamespace,
                    horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                    isHoveringMusicArea: $isHoveringMusicArea
                )
                .frame(maxWidth: .infinity)
                .frame(height: 102)
                .padding(.horizontal, 12)
                .background(rexSurface, in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.08)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 834)
        .onAppear { updateHeight() }
        .onChange(of: music.isPlaying) { _, _ in updateHeight() }
    }

    private func updateHeight() {
        vm.notchSize = CGSize(width: openNotchSize.width, height: music.isPlaying ? 390 : 288)
    }
}

private struct RexUsageCard: View {
    @ObservedObject var data: RexDashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.effectiveAccent)
                Text("Plan usage").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { data.refreshUsage() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(rexMuted)
                }.buttonStyle(.plain).help("Refresh Claude and Codex usage")
            }
            quota("Claude", data.claude, claudeColor)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            quota("Codex", data.codex, codexColor)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(rexSurface, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.08)))
    }

    private func quota(_ name: String, _ quota: RexQuota, _ color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let plan = quota.plan {
                    Text(plan.capitalized).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(color.opacity(0.14), in: Capsule())
                }
            }
            if quota.session == nil && quota.week == nil {
                Text(quota.status).font(.system(size: 11)).foregroundStyle(rexMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                usageBar("Session", quota.session, quota.sessionReset, color)
                usageBar("Week", quota.week, quota.weekReset, color)
            }
        }
    }

    private func usageBar(_ name: String, _ percent: Double?, _ reset: Date?, _ color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(name)
                if let reset { Text("↻ " + resetText(reset)).foregroundStyle(rexMuted) }
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").fontWeight(.bold)
            }
            .font(.system(size: 10))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, (percent ?? 0) / 100)))
                }
            }
            .frame(height: 5)
        }
    }

    private func resetText(_ reset: Date) -> String {
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }
}
