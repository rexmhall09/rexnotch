import Defaults
import SwiftUI

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
    @ObservedObject private var retention = RexNowPlayingRetention.shared
    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @Binding var isHoveringMusicArea: Bool

    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 16) {
                RexUsageCard(data: data).frame(maxWidth: .infinity)
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 1, height: 192)
                CalendarView()
                    .environmentObject(vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onHover { vm.isHoveringCalendar = $0 }
            }
            .frame(height: 200)

            if music.isPlaying || retention.showsPausedTrack {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                RexNowPlayingRow(
                    albumArtNamespace: albumArtNamespace,
                    horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                    isHoveringMusicArea: $isHoveringMusicArea
                )
                .frame(maxWidth: .infinity)
                .frame(height: 98)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 734)
        .onAppear { updateHeight() }
        .onChange(of: music.isPlaying) { _, _ in updateHeight() }
        .onChange(of: retention.showsPausedTrack) { _, _ in updateHeight() }
    }

    private func updateHeight() {
        vm.notchSize = CGSize(width: openNotchSize.width,
                              height: music.isPlaying || retention.showsPausedTrack ? 365 : 255)
    }
}

private struct RexUsageCard: View {
    @ObservedObject var data: RexDashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            quota("Claude", data.claude, claudeColor)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            quota("Codex", data.codex, codexColor)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                if name == "Claude" {
                    Button { data.refreshUsage() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(rexMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(data.isRefreshingUsage)
                    .help("Refresh Claude and Codex usage")
                    .accessibilityLabel("Refresh Claude and Codex usage")
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
                if let reset { Text(resetText(reset)).foregroundStyle(rexMuted) }
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

@MainActor
final class RexNowPlayingRetention: ObservableObject {
    static let shared = RexNowPlayingRetention()

    @Published private(set) var showsPausedTrack = false
    private var isNotchOpen = false
    private var expirationTask: Task<Void, Never>?

    func playbackChanged(isPlaying: Bool, hasTrack: Bool) {
        expirationTask?.cancel()
        if isPlaying || !hasTrack {
            showsPausedTrack = false
        } else {
            showsPausedTrack = true
            if !isNotchOpen { scheduleExpiration() }
        }
    }

    func notchDidOpen() {
        isNotchOpen = true
        expirationTask?.cancel()
    }

    func notchDidClose() {
        isNotchOpen = false
        if showsPausedTrack { scheduleExpiration() }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, !isNotchOpen else { return }
            showsPausedTrack = false
        }
    }
}

private struct RexNowPlayingRow: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var music = MusicManager.shared
    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @Binding var isHoveringMusicArea: Bool
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    @State private var lastDragged = Date.distantPast
    @Default(.showRemainingTime) private var showRemainingTime

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(music.songTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(music.artistName).font(.system(size: 11)).foregroundStyle(rexMuted).lineLimit(1)
                if Defaults[.enableLyrics], music.isPlaying {
                    TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                        Text(lyricLine(at: timeline.date))
                            .font(.system(size: 11))
                            .foregroundStyle(rexMuted)
                            .lineLimit(1)
                    }
                }
                MusicPlaybackTimeline(playbackRate: music.playbackRate) { date in
                    MusicSliderView(
                        sliderValue: $sliderValue,
                        duration: $music.songDuration,
                        lastDragged: $lastDragged,
                        color: music.avgColor,
                        dragging: $dragging,
                        currentDate: date,
                        timestampDate: music.timestampDate,
                        elapsedTime: music.elapsedTime,
                        playbackRate: music.playbackRate,
                        isPlaying: music.isPlaying,
                        onValueChange: { music.seek(to: $0) },
                        trailingLabel: showRemainingTime ? .remaining : .duration
                    )
                    .frame(height: 29)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                MusicControlSlotButton(slot: .previous, horizontalMediaGestureFeedback: horizontalMediaGestureFeedback)
                MusicControlSlotButton(slot: .playPause, horizontalMediaGestureFeedback: horizontalMediaGestureFeedback)
                MusicControlSlotButton(slot: .next, horizontalMediaGestureFeedback: horizontalMediaGestureFeedback)
            }
            .frame(width: 108)
        }
        .frame(height: 98)
        .contentShape(Rectangle())
        .onHover { isHoveringMusicArea = $0 }
        .onDisappear { isHoveringMusicArea = false }
    }

    private func lyricLine(at date: Date) -> String {
        if LyricsService.shared.isFetchingLyrics { return "Loading lyrics…" }
        if !LyricsService.shared.syncedLyrics.isEmpty {
            let elapsed = music.isPlaying
                ? min(max(music.elapsedTime + date.timeIntervalSince(music.timestampDate) * music.playbackRate, 0), music.songDuration)
                : music.elapsedTime
            return LyricsService.shared.lyricLineContext(at: elapsed).text
        }
        let line = music.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "No lyrics found" : line.replacingOccurrences(of: "\n", with: " ")
    }
}
