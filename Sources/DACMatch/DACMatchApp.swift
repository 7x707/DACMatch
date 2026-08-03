import SwiftUI

@main
struct DACMatchApp: App {
    @StateObject private var state: AppState

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        state.start()
    }

    var body: some Scene {
        MenuBarExtra(state.menuBarTitle, systemImage: "waveform") {
            DACMatchMenu(state: state)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct DACMatchMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if let track = state.track {
                Text(track.name)
                Text(track.artist.isEmpty ? "未知艺人" : track.artist)
                Text("源：\(SampleRateFormatter.string(track.sampleRate))")
            } else {
                Text("Apple Music 未在播放")
            }

            Text("DAC：\(state.selectedDeviceName)")
            if let rate = state.deviceSampleRate {
                Text("输出：\(SampleRateFormatter.string(rate))")
            }
            Text(state.statusText)

            Divider()

            Toggle("自动匹配采样率", isOn: $state.autoMatchEnabled)

            Menu("输出设备") {
                if state.devices.isEmpty {
                    Text("没有找到输出设备")
                }
                ForEach(state.devices) { device in
                    Button {
                        state.selectDevice(device)
                    } label: {
                        if device.uid == state.selectedDeviceUID {
                            Label(device.displayName, systemImage: "checkmark")
                        } else {
                            Text(device.displayName)
                        }
                    }
                }
                Divider()
                Button("重新扫描") { state.refreshDevices() }
            }

            Menu("DAC 锁定等待：\(delayLabel(state.dacLockDelaySeconds))") {
                ForEach([0.5, 1.0, 2.0, 3.0, 5.0], id: \.self) { seconds in
                    Button {
                        state.dacLockDelaySeconds = seconds
                    } label: {
                        if state.dacLockDelaySeconds == seconds {
                            Label(delayLabel(seconds), systemImage: "checkmark")
                        } else {
                            Text(delayLabel(seconds))
                        }
                    }
                }
            }

            Button(state.launchAtLogin ? "关闭登录时启动" : "登录时启动") {
                state.setLaunchAtLogin(!state.launchAtLogin)
            }

            Divider()

            Button("退出 DAC Match") {
                state.stop()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func delayLabel(_ seconds: Double) -> String {
        seconds.rounded() == seconds
            ? "\(Int(seconds)) 秒"
            : String(format: "%.1f 秒", seconds)
    }
}
