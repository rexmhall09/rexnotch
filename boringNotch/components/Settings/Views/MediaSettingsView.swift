//
//  MediaSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct MediaSettingsView: View {
    @ObservedObject private var musicManager = MusicManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: mediaControllerSelection) {
                    ForEach(MediaControllerType.allCases) { controller in
                        Text(controller.localizedResource)
                            .tag(controller)
                            .disabled(
                                controller == .nowPlaying
                                    && !musicManager.nowPlayingAvailability.isSelectable
                            )
                    }
                }
            } header: {
                Text("Media Source")
            } footer: {
                mediaSourceFooter
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .showRemainingTime) {
                    Text("Show remaining time instead of duration")
                }
            } header: {
                Text("Media controls")
            }  footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Media")
        .task {
            musicManager.ensureNowPlayingAvailabilityChecked()
        }
    }

    private var mediaControllerSelection: Binding<MediaControllerType> {
        Binding(
            get: { musicManager.preferredMediaController },
            set: { selectedController in
                guard selectedController != musicManager.preferredMediaController else { return }
                musicManager.selectMediaController(selectedController)
            }
        )
    }

    @ViewBuilder
    private var mediaSourceFooter: some View {
        let availability = musicManager.nowPlayingAvailability

        if availability == .checking {
            footerText("Checking Now Playing availability...")
        } else if let message = availability.settingsMessage {
            VStack(alignment: .leading, spacing: 6) {
                footerText(message)

                if musicManager.preferredMediaController == .nowPlaying,
                   let effectiveController = musicManager.effectiveMediaController,
                   effectiveController != .nowPlaying {
                    if availability.usesTemporaryFallback {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) temporarily. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a temporary Now Playing fallback. The placeholder is the active fallback source."
                            )
                        )
                    } else {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) instead. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a non-recoverable Now Playing setup failure. The placeholder is the active fallback source."
                            )
                        )
                    }
                }

                if availability.offersManualRetry {
                    Button("Check Again") {
                        musicManager.refreshNowPlayingAvailability()
                    }
                    .font(.caption)
                }
            }
        } else {
            footerText(
                "'Now Playing' was the only option on previous versions and works with all media apps."
            )
        }
    }

    private func footerText(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.caption)
    }
}
