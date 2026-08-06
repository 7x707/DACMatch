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
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        switch state.menuBarDisplayMode {
        case .iconOnly:
            Image(systemName: "waveform")
                .accessibilityLabel("DAC Match")
        case .rateOnly:
            Text(state.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("DAC Match \(state.menuBarTitle)")
        }
    }
}

private struct DACMatchPanel: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsExpanded = false
    @State private var statusVisible = true
    @State private var statusHideTask: Task<Void, Never>?

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
                    Label(state.text(.rematch), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.track == nil)

                Button {
                    state.recoverAudio()
                } label: {
                    Label(state.text(.recoverSound), systemImage: "speaker.wave.2")
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
                Button(state.text(.quit)) {
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
        .onAppear {
            state.preparePanelPresentation()
        }
        .onReceive(state.$statusText) { _ in
            refreshStatusVisibility()
        }
        .onDisappear {
            statusHideTask?.cancel()
            state.panelDidDisappear()
        }
    }

    private var nowPlayingHeader: some View {
        HStack(spacing: 14) {
            artworkView

            VStack(alignment: .leading, spacing: 5) {
                Text(state.track?.name ?? state.text(.noTrack))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)

                Text(
                    state.track.map { $0.artist.isEmpty ? state.text(.unknownArtist) : $0.artist }
                        ?? state.text(.startAppleMusic)
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label(connectionLabel, systemImage: playbackSymbol)
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
                    value: sourceRateLabel
                )

                Image(systemName: "arrow.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)

                outputRateMetric
            }
            .transaction { transaction in
                transaction.animation = nil
            }

            if statusVisible {
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
                .transition(.opacity)
            }
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
            Button {
                if reduceMotion {
                    settingsExpanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 1)) {
                        settingsExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(state.text(.settings))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if settingsExpanded {
                Group {
                    insetDivider

                    Toggle(isOn: $state.autoMatchEnabled) {
                        settingLabel(
                            icon: "waveform.badge.checkmark",
                            title: state.text(.autoMatch),
                            value: state.autoMatchEnabled ? state.text(.enabled) : state.text(.disabled)
                        )
                    }
                    .toggleStyle(.switch)
                    .padding(12)

                    insetDivider

                    HStack(spacing: 11) {
                        settingTitle(icon: "menubar.rectangle", title: state.text(.menuBarDisplay))
                        Spacer(minLength: 10)
                        Menu {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Button {
                                    state.menuBarDisplayMode = mode
                                } label: {
                                    if mode == state.menuBarDisplayMode {
                                        Label(state.text(mode.copyKey), systemImage: "checkmark")
                                    } else {
                                        Text(state.text(mode.copyKey))
                                    }
                                }
                            }
                        } label: {
                            menuValueLabel(state.text(state.menuBarDisplayMode.copyKey))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                    }
                    .padding(12)

                    insetDivider

                    HStack(spacing: 11) {
                        settingTitle(icon: "globe", title: state.text(.language))
                        Spacer(minLength: 10)
                        Menu {
                            ForEach(AppLanguage.allCases) { language in
                                Button {
                                    state.language = language
                                } label: {
                                    if language == state.language {
                                        Label(language.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(language.displayName)
                                    }
                                }
                            }
                        } label: {
                            menuValueLabel(state.language.displayName)
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
                            title: state.text(.launchAtLogin),
                            value: state.launchAtLogin ? state.text(.enabled) : state.text(.disabled)
                        )
                    }
                    .toggleStyle(.switch)
                    .padding(12)
                }
                .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    private var outputRateMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                if state.devices.isEmpty {
                    Text(state.text(.noDevices))
                }
                ForEach(state.devices) { device in
                    Button {
                        state.selectDevice(device)
                    } label: {
                        if device.uid == state.actualOutputDeviceUID {
                            Label(deviceMenuName(device), systemImage: "checkmark")
                        } else {
                            Text(deviceMenuName(device))
                        }
                    }
                }
                Divider()
                Button(state.text(.rescan)) { state.refreshDevices() }
            } label: {
                HStack(spacing: 4) {
                    Text(state.selectedDeviceName.uppercased())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            Text(state.deviceSampleRate.map(SampleRateFormatter.string) ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func refreshStatusVisibility() {
        statusHideTask?.cancel()
        if reduceMotion {
            statusVisible = true
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                statusVisible = true
            }
        }
        guard shouldAutoHideMatchedStatus else { return }
        statusHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, shouldAutoHideMatchedStatus else { return }
            if reduceMotion {
                statusVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    statusVisible = false
                }
            }
        }
    }

    private var shouldAutoHideMatchedStatus: Bool {
        state.statusText == state.text(.matched)
            || state.statusText == state.text(.matchedPlaying)
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
        AppCopy.isSuccessStatus(state.statusText)
    }

    private var isProgressStatus: Bool {
        AppCopy.isProgressStatus(state.statusText)
    }

    private var playbackLabel: String {
        switch state.playbackState {
        case .playing: return state.text(.playing)
        case .paused: return state.text(.paused)
        case .stopped: return state.text(.appleMusic)
        }
    }

    private var connectionLabel: String {
        guard state.musicConnected else { return state.text(.connecting) }
        guard state.playbackState != .stopped else { return state.text(.appleMusic) }
        return "\(state.text(.appleMusic)) · \(playbackLabel)"
    }

    private var playbackSymbol: String {
        guard state.musicConnected else { return "link" }
        switch state.playbackState {
        case .playing: return "waveform"
        case .paused: return "pause.fill"
        case .stopped: return "music.note"
        }
    }

    private var playbackTint: Color {
        guard state.musicConnected else { return .orange }
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

    private var sourceRateLabel: String {
        guard let rate = state.track?.sampleRate, rate > 0 else { return "—" }
        return SampleRateFormatter.string(rate)
    }

    private func deviceMenuName(_ device: AudioDevice) -> String {
        device.uid == state.actualOutputDeviceUID
            ? device.name + state.text(.currentDefault)
            : device.name
    }
}
