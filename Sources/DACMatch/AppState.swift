import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var track: MusicTrack?
    @Published private(set) var playbackState: MusicPlaybackState = .stopped
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var deviceSampleRate: Double?
    @Published private(set) var statusText = "正在启动…"
    @Published private(set) var diagnosticText: String?
    @Published var autoMatchEnabled: Bool {
        didSet { defaults.set(autoMatchEnabled, forKey: Keys.autoMatch) }
    }
    @Published var selectedDeviceUID: String? {
        didSet {
            defaults.set(selectedDeviceUID, forKey: Keys.deviceUID)
            lastAppliedTrackID = nil
            refreshDeviceRate()
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published var dacLockDelaySeconds: Double {
        didSet {
            defaults.set(dacLockDelaySeconds, forKey: Keys.dacLockDelay)
            lastAppliedTrackID = nil
            switchAttemptsForTrack = 0
            nextRetryDate = nil
            diagnosticText = nil
            statusText = "等待时间已更新，准备重新匹配"
        }
    }

    private let defaults: UserDefaults
    private let audioManager = CoreAudioDeviceManager()
    private let musicMonitor = MusicMonitor()
    private var timer: Timer?
    private var lastAppliedTrackID: String?
    private var consecutiveErrorKey: String?
    private var isSwitching = false
    private var observedTrackID: String?
    private var switchAttemptsForTrack = 0
    private var nextRetryDate: Date?
    private let maximumSwitchAttempts = 4
    private var artworkTrackID: String?
    private var artworkLoadAttempts = 0
    private var nextArtworkLoadDate: Date?
    private var lastDeviceRefreshDate: Date?

    private enum Keys {
        static let autoMatch = "autoMatchEnabled"
        static let deviceUID = "selectedDeviceUID"
        static let dacLockDelay = "dacLockDelaySeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.autoMatch) == nil {
            autoMatchEnabled = true
        } else {
            autoMatchEnabled = defaults.bool(forKey: Keys.autoMatch)
        }
        selectedDeviceUID = defaults.string(forKey: Keys.deviceUID)
        dacLockDelaySeconds = defaults.object(forKey: Keys.dacLockDelay) as? Double ?? 2.0
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard timer == nil else { return }
        refreshDevices()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshDevices() {
        do {
            devices = try audioManager.outputDevices()
            let activeDevice = devices.first(where: \.isDefaultOutput) ?? devices.first
            if selectedDeviceUID != activeDevice?.uid {
                selectedDeviceUID = activeDevice?.uid
                switchAttemptsForTrack = 0
                nextRetryDate = nil
            }
            lastDeviceRefreshDate = Date()
            refreshDeviceRate()
        } catch {
            setError(error)
        }
    }

    func selectDevice(_ device: AudioDevice) {
        guard !isSwitching else { return }
        isSwitching = true
        statusText = "正在安全切换到 \(device.name)…"
        diagnosticText = nil
        Task { @MainActor [weak self] in
            await self?.switchOutputDevice(to: device)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            setError(error)
        }
    }

    func forceRematch() {
        lastAppliedTrackID = nil
        switchAttemptsForTrack = 0
        nextRetryDate = nil
        diagnosticText = nil
        statusText = "正在重新匹配…"
        poll()
    }

    func recoverAudio() {
        guard !isSwitching, track != nil else { return }
        isSwitching = true
        statusText = "正在重建 Apple Music 音频流…"
        diagnosticText = nil
        Task { @MainActor [weak self] in
            await self?.rebuildAudioStream()
        }
    }

    var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    var selectedDeviceName: String {
        selectedDevice?.name ?? "未选择 DAC"
    }

    var menuBarTitle: String {
        guard let track, track.sampleRate > 0 else { return "DAC" }
        let source = SampleRateFormatter.string(track.sampleRate).replacingOccurrences(of: " kHz", with: "k")
        if let deviceSampleRate {
            let output = SampleRateFormatter.string(deviceSampleRate).replacingOccurrences(of: " kHz", with: "k")
            return source == output ? source : "\(source)→\(output)"
        }
        return source
    }

    private func poll() {
        guard !isSwitching else { return }
        do {
            if lastDeviceRefreshDate == nil
                || Date().timeIntervalSince(lastDeviceRefreshDate!) >= 2 {
                refreshDevices()
            }
            let snapshot = try musicMonitor.snapshot()
            let newTrack = snapshot.track
            track = newTrack
            playbackState = snapshot.state
            consecutiveErrorKey = nil

            guard let newTrack else {
                statusText = "请在 Apple Music 中选择一首歌曲"
                lastAppliedTrackID = nil
                observedTrackID = nil
                switchAttemptsForTrack = 0
                nextRetryDate = nil
                artworkImage = nil
                artworkTrackID = nil
                artworkLoadAttempts = 0
                refreshDeviceRate()
                return
            }
            if observedTrackID != newTrack.persistentID {
                observedTrackID = newTrack.persistentID
                switchAttemptsForTrack = 0
                lastAppliedTrackID = nil
                nextRetryDate = nil
                diagnosticText = nil
                artworkImage = nil
                artworkTrackID = newTrack.persistentID
                artworkLoadAttempts = 0
                nextArtworkLoadDate = nil
            }
            loadArtworkIfNeeded(for: newTrack)
            guard newTrack.sampleRate > 0 else {
                statusText = "当前曲目没有可用的采样率信息"
                return
            }
            guard autoMatchEnabled else {
                statusText = "自动匹配已暂停"
                refreshDeviceRate()
                return
            }
            guard let device = selectedDevice else {
                statusText = "请选择输出 DAC"
                return
            }

            let currentRate = try audioManager.currentSampleRate(for: device.id)
            if abs(currentRate - newTrack.sampleRate) < 1 {
                lastAppliedTrackID = newTrack.persistentID
                deviceSampleRate = currentRate
                nextRetryDate = nil
                diagnosticText = nil
                statusText = snapshot.state == .playing
                    ? "采样率已匹配"
                    : "已预匹配，等待播放"
                return
            }

            deviceSampleRate = currentRate
            lastAppliedTrackID = nil
            if let nextRetryDate, nextRetryDate > Date() {
                statusText = "等待自动重试…"
                return
            }
            guard switchAttemptsForTrack < maximumSwitchAttempts else {
                statusText = "输出仍不匹配，请点“立即重新匹配”"
                return
            }

            isSwitching = true
            switchAttemptsForTrack += 1
            statusText = "正在安全切换采样率…"
            Task { @MainActor [weak self] in
                await self?.switchSampleRate(
                    to: newTrack.sampleRate,
                    trackID: newTrack.persistentID,
                    device: device,
                    musicWasPlaying: snapshot.state == .playing,
                    playWhenFinished: snapshot.state == .playing
                )
            }
        } catch {
            setError(error)
        }
    }

    private func switchSampleRate(
        to rate: Double,
        trackID: String,
        device: AudioDevice,
        musicWasPlaying: Bool,
        playWhenFinished: Bool
    ) async {
        var didPause = false
        var resumePosition: Double?
        var stage = "准备切换"
        defer {
            if didPause {
                do {
                    try musicMonitor.play()
                    if let resumePosition {
                        try? musicMonitor.setPlayerPosition(resumePosition)
                    }
                } catch {
                    setError(error)
                }
            }
            isSwitching = false
        }

        do {
            if musicWasPlaying {
                resumePosition = try? musicMonitor.playerPosition()
                stage = "暂停 Apple Music"
                try musicMonitor.pause()
                didPause = true

                // Give Apple Music time to release its old Core Audio stream before
                // changing the hardware clock. Some USB DACs otherwise stop receiving audio.
                try await Task<Never, Never>.sleep(nanoseconds: 650_000_000)
            }

            stage = "写入 DAC 采样率"
            try audioManager.setSampleRate(rate, for: device)

            // Observe until the new rate stays stable instead of trusting one instant read.
            // The selected lock delay is a maximum wait, not a mandatory fixed pause.
            stage = "等待 DAC 稳定锁定"
            let confirmedRate = try await waitForStableSampleRate(
                rate,
                device: device,
                timeout: max(0.5, dacLockDelaySeconds) + 0.25,
                stableFor: 0.25
            )

            if playWhenFinished {
                stage = "恢复 Apple Music"
                try musicMonitor.play()
                didPause = false
                if let resumePosition {
                    try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                    // Seeking nudges Music to refresh the stream, but failure to restore
                    // an exact position must never invalidate a successful rate switch.
                    try? musicMonitor.setPlayerPosition(resumePosition)
                }

                // A longer stable window catches devices that briefly report the target
                // rate and then fall back while Music recreates its output stream.
                stage = "验证恢复后的输出"
                let postResumeRate = try await waitForStableSampleRate(
                    rate,
                    device: device,
                    timeout: max(1.5, dacLockDelaySeconds + 0.6),
                    stableFor: 0.6
                )
                deviceSampleRate = postResumeRate
                playbackState = .playing
            } else {
                deviceSampleRate = confirmedRate
            }

            lastAppliedTrackID = trackID
            nextRetryDate = nil
            diagnosticText = nil
            statusText = playWhenFinished ? "采样率已匹配，正在播放" : "已预匹配，等待播放"
        } catch {
            scheduleRetry(afterFailureAt: stage, error: error)
        }
    }

    private func switchOutputDevice(to device: AudioDevice) async {
        var needsResume = false
        var resumePosition: Double?
        var stage = "准备切换输出设备"

        defer {
            if needsResume {
                try? musicMonitor.play()
                if let resumePosition { try? musicMonitor.setPlayerPosition(resumePosition) }
            }
            isSwitching = false
        }

        do {
            let snapshot = try musicMonitor.snapshot()
            let currentTrack = snapshot.track ?? track
            let wasPlaying = snapshot.state == .playing

            if wasPlaying {
                resumePosition = try? musicMonitor.playerPosition()
                stage = "暂停 Apple Music"
                try musicMonitor.pause()
                needsResume = true

                // Let Music release the stream owned by the previous output device.
                try await Task<Never, Never>.sleep(nanoseconds: 650_000_000)
            }

            stage = "切换系统输出设备"
            try audioManager.setDefaultOutputDevice(device.id)

            stage = "确认系统输出设备"
            try await waitForDefaultOutputDevice(device.id, timeout: 2.0)
            selectedDeviceUID = device.uid

            // Give macOS time to publish the new route before configuring its clock.
            try await Task<Never, Never>.sleep(nanoseconds: 350_000_000)

            if let currentTrack, currentTrack.sampleRate > 0 {
                stage = "写入新设备采样率"
                let currentRate = try audioManager.currentSampleRate(for: device.id)
                if abs(currentRate - currentTrack.sampleRate) >= 1 {
                    try audioManager.setSampleRate(currentTrack.sampleRate, for: device)
                }

                stage = "等待新设备稳定锁定"
                deviceSampleRate = try await waitForStableSampleRate(
                    currentTrack.sampleRate,
                    device: device,
                    timeout: max(1.0, dacLockDelaySeconds) + 0.5,
                    stableFor: 0.35
                )
                lastAppliedTrackID = currentTrack.persistentID
            } else {
                deviceSampleRate = try? audioManager.currentSampleRate(for: device.id)
                lastAppliedTrackID = nil
            }

            if wasPlaying {
                stage = "在新设备上恢复 Apple Music"
                try musicMonitor.play()
                needsResume = false
                if let resumePosition {
                    try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                    try? musicMonitor.setPlayerPosition(resumePosition)
                }

                stage = "确认新设备音频流"
                do {
                    try await waitForDeviceToStartRunning(device.id, timeout: 1.2)
                } catch {
                    // The route and clock can look correct while Music still owns a
                    // stale stream. Reopen it once before reporting success.
                    stage = "重新建立新设备音频流"
                    try musicMonitor.pause()
                    needsResume = true
                    try await Task<Never, Never>.sleep(nanoseconds: 450_000_000)
                    try musicMonitor.play()
                    needsResume = false
                    if let resumePosition {
                        try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                        try? musicMonitor.setPlayerPosition(resumePosition)
                    }
                    try await waitForDeviceToStartRunning(device.id, timeout: 1.5)
                }
            }

            switchAttemptsForTrack = 0
            nextRetryDate = nil
            diagnosticText = nil
            statusText = wasPlaying
                ? "已切换到 \(device.name)，正在播放"
                : "系统输出已切换到 \(device.name)"
            refreshDevices()
        } catch {
            diagnosticText = "\(stage)：\(error.localizedDescription)"
            statusText = "切换到 \(device.name) 失败"
        }
    }

    private func rebuildAudioStream() async {
        var needsResume = false
        let position = try? musicMonitor.playerPosition()
        defer {
            if needsResume {
                try? musicMonitor.play()
                if let position { try? musicMonitor.setPlayerPosition(position) }
            }
            isSwitching = false
        }

        do {
            try musicMonitor.pause()
            needsResume = true
            try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            try musicMonitor.play()
            needsResume = false
            if let position {
                try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                try? musicMonitor.setPlayerPosition(position)
            }
            try await Task<Never, Never>.sleep(nanoseconds: 400_000_000)
            statusText = "音频流已刷新，请确认声音"
            diagnosticText = nil
        } catch {
            diagnosticText = "重建音频流：\(error.localizedDescription)"
            statusText = "恢复声音失败"
        }
    }

    private func waitForStableSampleRate(
        _ targetRate: Double,
        device: AudioDevice,
        timeout: TimeInterval,
        stableFor requiredStableDuration: TimeInterval
    ) async throws -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        var lastObservedRate = try audioManager.currentSampleRate(for: device.id)

        while Date() < deadline {
            lastObservedRate = try audioManager.currentSampleRate(for: device.id)
            if abs(lastObservedRate - targetRate) < 1 {
                if stableSince == nil { stableSince = Date() }
                if let stableSince,
                   Date().timeIntervalSince(stableSince) >= requiredStableDuration {
                    return lastObservedRate
                }
            } else {
                stableSince = nil
            }
            try await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        }

        throw CoreAudioError.propertyUnavailable(
            "等待 \(SampleRateFormatter.string(targetRate)) 超时，最后检测到 \(SampleRateFormatter.string(lastObservedRate))"
        )
    }

    private func waitForDefaultOutputDevice(
        _ targetDeviceID: AudioObjectID,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try audioManager.currentDefaultOutputDeviceID() == targetDeviceID {
                return
            }
            try await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        }
        throw CoreAudioError.propertyUnavailable("系统没有确认新的默认输出设备")
    }

    private func waitForDeviceToStartRunning(
        _ deviceID: AudioObjectID,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try audioManager.isDeviceRunning(deviceID) {
                return
            }
            try await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        }
        throw CoreAudioError.propertyUnavailable("新输出设备没有检测到音频流")
    }

    private func scheduleRetry(afterFailureAt stage: String, error: Error) {
        diagnosticText = "\(stage)：\(error.localizedDescription)"
        guard switchAttemptsForTrack < maximumSwitchAttempts else {
            nextRetryDate = nil
            statusText = "自动重试已暂停，请手动重新匹配"
            return
        }

        let attemptIndex = Double(max(0, switchAttemptsForTrack - 1))
        let delay = min(pow(2.0, attemptIndex) * 0.5, 3.0)
        nextRetryDate = Date().addingTimeInterval(delay)
        statusText = String(format: "匹配未稳定，%.1f 秒后重试", delay)
    }

    private func refreshDeviceRate() {
        guard let device = selectedDevice else {
            deviceSampleRate = nil
            return
        }
        do {
            deviceSampleRate = try audioManager.currentSampleRate(for: device.id)
        } catch {
            deviceSampleRate = nil
            setError(error)
        }
    }

    private func loadArtworkIfNeeded(for currentTrack: MusicTrack) {
        guard artworkTrackID == currentTrack.persistentID,
              artworkImage == nil,
              artworkLoadAttempts < 8
        else { return }
        if let nextArtworkLoadDate, nextArtworkLoadDate > Date() { return }

        artworkLoadAttempts += 1
        nextArtworkLoadDate = Date().addingTimeInterval(1)
        guard let data = try? musicMonitor.currentArtworkData(),
              let image = NSImage(data: data)
        else { return }
        artworkImage = image
        nextArtworkLoadDate = nil
    }

    private func setError(_ error: Error) {
        let message = error.localizedDescription
        guard consecutiveErrorKey != message else { return }
        consecutiveErrorKey = message
        statusText = message
    }
}
