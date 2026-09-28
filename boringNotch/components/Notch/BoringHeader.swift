//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var rexData = RexDashboardData.shared
    @ObservedObject var controls = RexSystemControls.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if vm.notchState == .open {
                    RexMetricLabel(name: "CPU", value: rexData.cpu)
                    RexMetricLabel(name: "GPU", value: rexData.gpu)
                    RexMetricLabel(name: "RAM", value: rexData.ram)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 8) {
                if vm.notchState == .open {
                    if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                        OpenNotchOSD(
                             type: coordinator.binding(for: vm.screenUUID).type,
                             value: coordinator.binding(for: vm.screenUUID).value,
                             icon: coordinator.binding(for: vm.screenUUID).icon,
                             accent: coordinator.binding(for: vm.screenUUID).accent
                        )
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        Button {
                            controls.cyclePower()
                        } label: {
                            Label(controls.mode.title, systemImage: controls.mode.symbol)
                                .foregroundStyle(Color.effectiveAccent)
                        }
                        .disabled(controls.isChangingPower)
                        .help("Cycle Normal → Battery Saver → Keep Awake")

                        Button(controls.isUpdating ? "Updating…" : "Update All") { controls.startUpdateAll() }
                            .disabled(controls.isUpdating)
                            .help(controls.updateStatus.isEmpty ? "Update Homebrew and Mac App Store apps" : controls.updateStatus)

                        Button {
                            SettingsWindowController.shared.showWindow()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Settings")
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
        .alert("RexNotch", isPresented: Binding(
            get: { controls.errorMessage != nil },
            set: { if !$0 { controls.errorMessage = nil } }
        )) {
            Button("OK") { controls.errorMessage = nil }
        } message: {
            Text(controls.errorMessage ?? "")
        }
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
