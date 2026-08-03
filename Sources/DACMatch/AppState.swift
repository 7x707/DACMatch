import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var track: MusicTrack?
    @Published private(set) var playbackState: MusicPlaybackState = .stopped
    @Published private(set) var deviceSampleRate: Double?
    @Published private(set) var statusText = "正在启动…"
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
            if selectedDevice == nil {
                selectedDeviceUID = devices.first(where: \.isDefaultOutput)?.uid ?? devices.first?.uid
            }
            refreshDeviceRate()
        } catch {
            setError(error)
        }
    }

    func selectDevice(_ device: AudioDevice) {
        selectedDeviceUID = device.uid
        statusText = "已选择 \(device.name)"
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
        statusText = "正在重新匹配…"
        poll()
    }

    func matchAndPlay() {
        guard !isSwitching else { return }
        do {
            let snapshot = try musicMonitor.snapshot()
            guard let currentTrack = snapshot.track else {
                statusText = "请先在 Apple Music 中选择一首歌曲"
                return
            }
            guard currentTrack.sampleRate > 0 else {
                statusText = "当前曲目没有可用的采样率信息"
                return
            }
            guard let device = selectedDevice else {
                statusText = "请选择输出 DAC"
                return
            }

            track = currentTrack
            playbackState = snapshot.state
            let currentRate = try audioManager.currentSampleRate(for: device.id)
            deviceSampleRate = currentRate
            if abs(currentRate - currentTrack.sampleRate) < 1 {
                try musicMonitor.play()
                playbackState = .playing
                statusText = "采样率已匹配，正在播放"
                return
            }

            switchAttemptsForTrack = 0
            isSwitching = true
            statusText = "正在匹配，完成后播放…"
            Task { @MainActor [weak self] in
                await self?.switchSampleRate(
                    to: currentTrack.sampleRate,
                    trackID: currentTrack.persistentID,
                    device: device,
                    musicWasPlaying: snapshot.state == .playing,
                    playWhenFinished: true
                )
            }
        } catch {
            setError(error)
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
                refreshDeviceRate()
                return
            }
            if observedTrackID != newTrack.persistentID {
                observedTrackID = newTrack.persistentID
                switchAttemptsForTrack = 0
                lastAppliedTrackID = nil
            }
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
                statusText = snapshot.state == .playing
                    ? "采样率已匹配"
                    : "已预匹配，等待播放"
                return
            }

            deviceSampleRate = currentRate
            lastAppliedTrackID = nil
            guard switchAttemptsForTrack < 3 else {
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
        defer {
            if didPause {
                do {
                    try musicMonitor.play()
                } catch {
                    setError(error)
                }
            }
            isSwitching = false
        }

        do {
            if musicWasPlaying {
                try musicMonitor.pause()
                didPause = true

                // Give Apple Music time to release its old Core Audio stream before
                // changing the hardware clock. Some USB DACs otherwise stop receiving audio.
                try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
            try audioManager.setSampleRate(rate, for: device)

            // Let the DAC lock to the new clock before Music recreates its stream.
            let lockDelay = UInt64(dacLockDelaySeconds * 1_000_000_000)
            try await Task<Never, Never>.sleep(nanoseconds: lockDelay)
            let confirmedRate = try audioManager.currentSampleRate(for: device.id)
            guard abs(confirmedRate - rate) < 1 else {
                throw CoreAudioError.propertyUnavailable("DAC 未确认新的采样率")
            }

            if playWhenFinished {
                try musicMonitor.play()
                didPause = false

                // Verify again after Music recreates its output stream. Some devices or
                // players can restore the previous hardware rate during resume.
                try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
                let postResumeRate = try audioManager.currentSampleRate(for: device.id)
                deviceSampleRate = postResumeRate
                guard abs(postResumeRate - rate) < 1 else {
                    throw CoreAudioError.propertyUnavailable(
                        "恢复播放后输出回到 \(SampleRateFormatter.string(postResumeRate))"
                    )
                }
                playbackState = .playing
            } else {
                deviceSampleRate = confirmedRate
            }

            lastAppliedTrackID = trackID
            statusText = playWhenFinished ? "采样率已匹配，正在播放" : "已预匹配，等待播放"
        } catch {
            setError(error)
        }
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

    private func setError(_ error: Error) {
        let message = error.localizedDescription
        guard consecutiveErrorKey != message else { return }
        consecutiveErrorKey = message
        statusText = message
    }
}
