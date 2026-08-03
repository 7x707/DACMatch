import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var track: MusicTrack?
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
        didSet { defaults.set(dacLockDelaySeconds, forKey: Keys.dacLockDelay) }
    }

    private let defaults: UserDefaults
    private let audioManager = CoreAudioDeviceManager()
    private let musicMonitor = MusicMonitor()
    private var timer: Timer?
    private var lastAppliedTrackID: String?
    private var consecutiveErrorKey: String?
    private var isSwitching = false

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
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
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
            let newTrack = try musicMonitor.currentTrack()
            track = newTrack
            consecutiveErrorKey = nil

            guard let newTrack else {
                statusText = "Apple Music 未在播放"
                lastAppliedTrackID = nil
                refreshDeviceRate()
                return
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
            guard lastAppliedTrackID != newTrack.persistentID else {
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
                statusText = "采样率已匹配"
                return
            }

            isSwitching = true
            statusText = "正在安全切换采样率…"
            Task { @MainActor [weak self] in
                await self?.switchSampleRate(
                    to: newTrack.sampleRate,
                    trackID: newTrack.persistentID,
                    device: device
                )
            }
        } catch {
            setError(error)
        }
    }

    private func switchSampleRate(
        to rate: Double,
        trackID: String,
        device: AudioDevice
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
            try musicMonitor.pause()
            didPause = true

            // Give Apple Music time to release its old Core Audio stream before
            // changing the hardware clock. Some USB DACs otherwise stop receiving audio.
            try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            try audioManager.setSampleRate(rate, for: device)

            // Let the DAC lock to the new clock before Music recreates its stream.
            let lockDelay = UInt64(dacLockDelaySeconds * 1_000_000_000)
            try await Task<Never, Never>.sleep(nanoseconds: lockDelay)
            let confirmedRate = try audioManager.currentSampleRate(for: device.id)
            guard abs(confirmedRate - rate) < 1 else {
                throw CoreAudioError.propertyUnavailable("DAC 未确认新的采样率")
            }

            deviceSampleRate = confirmedRate
            lastAppliedTrackID = trackID
            statusText = "采样率已匹配，即将恢复播放"
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
