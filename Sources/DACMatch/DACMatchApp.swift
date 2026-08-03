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
        MenuBarExtra {
            DACMatchPanel(state: state)
        } label: {
            Label(state.menuBarTitle, systemImage: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct DACMatchPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track = state.track {
                HStack(spacing: 12) {
                    artworkView

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(track.artist.isEmpty ? "未知艺人" : track.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Apple Music 未选择曲目")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 7) {
                infoRow(
                    "源格式",
                    value: state.track.map { SampleRateFormatter.string($0.sampleRate) } ?? "—"
                )
                infoRow("DAC", value: state.selectedDeviceName)
                infoRow(
                    "输出格式",
                    value: state.deviceSampleRate.map(SampleRateFormatter.string) ?? "—"
                )
            }

            Label(state.statusText, systemImage: statusSymbol)
                .font(.callout)
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .animation(.default, value: state.statusText)

            if let diagnostic = state.diagnosticText {
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

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
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("立即重新匹配") {
                state.forceRematch()
            }
            .buttonStyle(.bordered)
            .disabled(state.track == nil)

            Toggle(
                "登录时启动",
                isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                )
            )

            Divider()

            Button("退出 DAC Match") {
                state.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var artworkView: some View {
        Group {
            if let artwork = state.artworkImage {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
    }

    private var statusSymbol: String {
        if state.statusText.contains("已匹配") || state.statusText.contains("预匹配") {
            return "checkmark.circle.fill"
        }
        if state.statusText.contains("正在") || state.statusText.contains("准备") {
            return "arrow.triangle.2.circlepath"
        }
        return "exclamationmark.circle"
    }

    private var statusColor: Color {
        if state.statusText.contains("已匹配") || state.statusText.contains("预匹配") {
            return .green
        }
        if state.statusText.contains("正在") || state.statusText.contains("准备") {
            return .secondary
        }
        return .orange
    }

    private func delayLabel(_ seconds: Double) -> String {
        seconds.rounded() == seconds
            ? "\(Int(seconds)) 秒"
            : String(format: "%.1f 秒", seconds)
    }
}
