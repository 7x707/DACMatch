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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nowPlayingHeader
            rateCard

            if let diagnostic = state.diagnosticText {
                Label(diagnostic, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }

            settingsCard

            HStack(spacing: 8) {
                Button {
                    state.forceRematch()
                } label: {
                    Label("重新匹配", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.track == nil)

                Button {
                    state.recoverAudio()
                } label: {
                    Label("恢复声音", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.track == nil)
            }

            HStack {
                Text(appVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出") {
                    state.stop()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 370)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.statusText)
    }

    private var nowPlayingHeader: some View {
        HStack(spacing: 14) {
            artworkView

            VStack(alignment: .leading, spacing: 5) {
                Text(state.track?.name ?? "未选择曲目")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)

                Text(state.track.map { $0.artist.isEmpty ? "未知艺人" : $0.artist } ?? "请在 Apple Music 中开始播放")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label(playbackLabel, systemImage: playbackSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(playbackTint)
            }

            Spacer(minLength: 0)
        }
    }

    private var rateCard: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                rateMetric(
                    title: "APPLE MUSIC",
                    value: state.track.map { SampleRateFormatter.string($0.sampleRate) } ?? "—"
                )

                Image(systemName: "arrow.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)

                rateMetric(
                    title: state.selectedDeviceName.uppercased(),
                    value: state.deviceSampleRate.map(SampleRateFormatter.string) ?? "—"
                )
            }

            Divider()

            HStack(spacing: 9) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(state.statusText)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(statusColor)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $state.autoMatchEnabled) {
                settingLabel(
                    icon: "waveform.badge.checkmark",
                    title: "自动匹配采样率",
                    value: state.autoMatchEnabled ? "已开启" : "已关闭"
                )
            }
            .toggleStyle(.switch)
            .padding(12)

            insetDivider

            HStack(spacing: 11) {
                settingTitle(icon: "hifispeaker", title: "输出设备")
                Spacer(minLength: 10)
                Menu {
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
                } label: {
                    menuValueLabel(state.selectedDeviceName)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(12)

            insetDivider

            HStack(spacing: 11) {
                settingTitle(icon: "timer", title: "DAC 锁定等待")
                Spacer(minLength: 10)
                Menu {
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
                } label: {
                    menuValueLabel(delayLabel(state.dacLockDelaySeconds))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .padding(12)

            insetDivider

            Toggle(
                isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                )
            ) {
                settingLabel(
                    icon: "power",
                    title: "登录时启动",
                    value: state.launchAtLogin ? "已开启" : "已关闭"
                )
            }
            .toggleStyle(.switch)
            .padding(12)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
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
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private func rateMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingLabel(
        icon: String,
        title: String,
        value: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func settingTitle(icon: String, title: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.primary)
        }
    }

    private func menuValueLabel(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 155)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .contentShape(Capsule(style: .continuous))
    }

    private var insetDivider: some View {
        Divider().padding(.leading, 43)
    }

    private var statusSymbol: String {
        if isSuccessStatus {
            return "checkmark.circle.fill"
        }
        if isProgressStatus {
            return "arrow.triangle.2.circlepath"
        }
        return "exclamationmark.circle"
    }

    private var statusColor: Color {
        if isSuccessStatus {
            return .green
        }
        if isProgressStatus {
            return .secondary
        }
        return .orange
    }

    private var isSuccessStatus: Bool {
        ["已匹配", "预匹配", "已切换", "已刷新"].contains {
            state.statusText.contains($0)
        }
    }

    private var isProgressStatus: Bool {
        ["正在", "准备", "等待自动重试", "后重试"].contains {
            state.statusText.contains($0)
        }
    }

    private var playbackLabel: String {
        switch state.playbackState {
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .stopped: return "Apple Music"
        }
    }

    private var playbackSymbol: String {
        switch state.playbackState {
        case .playing: return "waveform"
        case .paused: return "pause.fill"
        case .stopped: return "music.note"
        }
    }

    private var playbackTint: Color {
        switch state.playbackState {
        case .playing: return .green
        case .paused: return .orange
        case .stopped: return .secondary
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "DAC Match  \($0)" } ?? "DAC Match"
    }

    private func delayLabel(_ seconds: Double) -> String {
        seconds.rounded() == seconds
            ? "\(Int(seconds)) 秒"
            : String(format: "%.1f 秒", seconds)
    }
}
