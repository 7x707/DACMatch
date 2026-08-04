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
    @Published private(set) var musicConnected = false
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var deviceSampleRate: Double?
    @Published private(set) var actualOutputDeviceUID: String?
    @Published private(set) var statusText = "正在启动…"
    @Published private(set) var diagnosticText: String?
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            diagnosticText = nil
            statusText = text(.starting)
            poll()
        }
    }
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
            statusText = text(.waitUpdated)
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
    private var observedTrackSampleRate: Double?
    private var previousTrackSampleRate: Double?
    private var switchAttemptsForTrack = 0
    private var nextRetryDate: Date?
    private let maximumSwitchAttempts = 4
    private var artworkTrackID: String?
    private var artworkLoadAttempts = 0
    private var nextArtworkLoadDate: Date?
    private var catalogArtworkTask: Task<Void, Never>?
    private var catalogArtworkRequestedTrackID: String?
    private var lastDeviceRefreshDate: Date?
    private var missingRatePollCount = 0

    private enum Keys {
        static let autoMatch = "autoMatchEnabled"
        static let deviceUID = "selectedDeviceUID"
        static let dacLockDelay = "dacLockDelaySeconds"
        static let language = "appLanguage"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "")
            ?? .simplifiedChinese
        if defaults.object(forKey: Keys.autoMatch) == nil {
            autoMatchEnabled = true
        } else {
            autoMatchEnabled = defaults.bool(forKey: Keys.autoMatch)
        }
        selectedDeviceUID = defaults.string(forKey: Keys.deviceUID)
        dacLockDelaySeconds = defaults.object(forKey: Keys.dacLockDelay) as? Double ?? 2.0
        launchAtLogin = SMAppService.mainApp.status == .enabled
        statusText = AppCopy.text(.starting, language: language)
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
        catalogArtworkTask?.cancel()
        catalogArtworkTask = nil
    }

    func refreshDevices() {
        do {
            devices = try audioManager.outputDevices()
            let activeDevice = devices.first(where: \.isDefaultOutput) ?? devices.first
            actualOutputDeviceUID = activeDevice?.uid
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
        statusText = text(.switchingTo, device.name)
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
        if (actualOutputDevice ?? selectedDevice)?.requiresRouteReset == true,
           track != nil,
           !isSwitching {
            recoverAudio()
            return
        }
        lastAppliedTrackID = nil
        switchAttemptsForTrack = 0
        nextRetryDate = nil
        diagnosticText = nil
        statusText = text(.rematching)
        poll()
    }

    func recoverAudio() {
        guard !isSwitching, track != nil else { return }
        isSwitching = true
        statusText = text(.rebuildingStream)
        diagnosticText = nil
        Task { @MainActor [weak self] in
            await self?.rebuildAudioStream()
        }
    }

    var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    var actualOutputDevice: AudioDevice? {
        devices.first { $0.uid == actualOutputDeviceUID }
    }

    var selectedDeviceName: String {
        actualOutputDevice?.name ?? selectedDevice?.name ?? text(.noDAC)
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

    func text(_ key: CopyKey, _ arguments: CVarArg...) -> String {
        AppCopy.text(key, language: language, arguments: arguments)
    }

    private func updateStage(_ key: CopyKey) -> String {
        let value = text(key)
        statusText = value
        return value
    }

    private func poll() {
        refreshLiveOutputState()
        if isSwitching {
            if let track { loadArtworkIfNeeded(for: track) }
            return
        }
        do {
            if lastDeviceRefreshDate == nil
                || Date().timeIntervalSince(lastDeviceRefreshDate!) >= 2 {
                refreshDevices()
            }
            let snapshot = try musicMonitor.snapshot()
            let newTrack = snapshot.track
            playbackState = snapshot.state
            musicConnected = true
            consecutiveErrorKey = nil

            guard let newTrack else {
                if snapshot.state != .stopped {
                    statusText = text(.waitingTrackInfo)
                    return
                }
                track = nil
                statusText = text(.selectSong)
                lastAppliedTrackID = nil
                observedTrackID = nil
                observedTrackSampleRate = nil
                previousTrackSampleRate = nil
                switchAttemptsForTrack = 0
                nextRetryDate = nil
                artworkImage = nil
                artworkTrackID = nil
                artworkLoadAttempts = 0
                catalogArtworkTask?.cancel()
                catalogArtworkTask = nil
                catalogArtworkRequestedTrackID = nil
                refreshDeviceRate()
                return
            }
            track = newTrack
            let trackChanged = observedTrackID != newTrack.persistentID
            if trackChanged {
                previousTrackSampleRate = observedTrackSampleRate
                observedTrackID = newTrack.persistentID
                observedTrackSampleRate = newTrack.sampleRate > 0 ? newTrack.sampleRate : nil
                switchAttemptsForTrack = 0
                lastAppliedTrackID = nil
                nextRetryDate = nil
                diagnosticText = nil
                artworkImage = nil
                artworkTrackID = newTrack.persistentID
                artworkLoadAttempts = 0
                nextArtworkLoadDate = nil
                catalogArtworkTask?.cancel()
                catalogArtworkTask = nil
                catalogArtworkRequestedTrackID = nil
                missingRatePollCount = 0
            } else if newTrack.sampleRate > 0 {
                observedTrackSampleRate = newTrack.sampleRate
            }
            loadArtworkIfNeeded(for: newTrack)
            guard newTrack.sampleRate > 0 else {
                missingRatePollCount += 1
                statusText = missingRatePollCount < 20 ? text(.waitingTrackInfo) : text(.noRate)
                return
            }
            missingRatePollCount = 0
            guard autoMatchEnabled else {
                statusText = text(.autoPaused)
                refreshDeviceRate()
                return
            }
            guard let device = actualOutputDevice ?? selectedDevice else {
                statusText = text(.selectDAC)
                return
            }

            let currentRate = try audioManager.currentSampleRate(for: device.id)
            if abs(currentRate - newTrack.sampleRate) < 1 {
                if snapshot.state == .playing,
                   device.requiresRouteReset,
                   lastAppliedTrackID != newTrack.persistentID,
                   StreamRefreshPolicy.requiresRefresh(
                       previousTrackRate: previousTrackSampleRate,
                       newTrackRate: newTrack.sampleRate
                   ) {
                    if let nextRetryDate, nextRetryDate > Date() {
                        statusText = text(.waitingRetry)
                        return
                    }
                    guard switchAttemptsForTrack < maximumSwitchAttempts else {
                        statusText = text(.retryPaused)
                        return
                    }
                    isSwitching = true
                    switchAttemptsForTrack += 1
                    statusText = text(.refreshingTrackStream)
                    Task { @MainActor [weak self] in
                        await self?.rebuildAudioStream(automatic: true)
                    }
                    return
                }
                lastAppliedTrackID = newTrack.persistentID
                deviceSampleRate = currentRate
                nextRetryDate = nil
                diagnosticText = nil
                statusText = snapshot.state == .playing
                    ? text(.matched)
                    : text(.prematched)
                return
            }

            deviceSampleRate = currentRate
            lastAppliedTrackID = nil
            if let nextRetryDate, nextRetryDate > Date() {
                statusText = text(.waitingRetry)
                return
            }
            guard switchAttemptsForTrack < maximumSwitchAttempts else {
                statusText = text(.outputMismatch)
                return
            }

            isSwitching = true
            switchAttemptsForTrack += 1
            statusText = text(.safeRateSwitch)
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
            musicConnected = false
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
        var mustRestoreOutputRoute = false
        var originalMusicVolume: Int?
        var musicIsTemporarilyMuted = false
        var resumedOnFallback = false
        var stage = text(.preparingSwitch)
        defer {
            if mustRestoreOutputRoute {
                try? audioManager.setDefaultOutputDevice(device.id)
                actualOutputDeviceUID = device.uid
            }
            if didPause {
                do {
                    try musicMonitor.play()
                    playbackState = .playing
                } catch {
                    setError(error)
                }
            }
            if musicIsTemporarilyMuted, let originalMusicVolume {
                try? musicMonitor.setSoundVolume(originalMusicVolume)
            }
            isSwitching = false
        }

        do {
            let fallback: AudioDevice?
            if device.requiresRouteReset {
                guard let availableFallback = fallbackOutputDevice(excluding: device) else {
                    throw CoreAudioError.propertyUnavailable(text(.noFallbackOutput))
                }
                fallback = availableFallback
            } else {
                fallback = nil
            }

            if musicWasPlaying, let fallback {
                // Keep an active (but silent) Music stream while routing away. A
                // route change performed only while paused can be ignored by Music,
                // leaving it attached to the DAC's old USB stream.
                originalMusicVolume = try musicMonitor.soundVolume()
                if originalMusicVolume != 0 {
                    try musicMonitor.setSoundVolume(0)
                    musicIsTemporarilyMuted = true
                }

                stage = updateStage(.routeAway)
                try audioManager.setDefaultOutputDevice(fallback.id)
                mustRestoreOutputRoute = true
                try await waitForDefaultOutputDevice(fallback.id, timeout: 2.0)
                actualOutputDeviceUID = fallback.uid
                try await waitForDeviceToStartRunning(fallback.id, timeout: 2.0)
                try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)

                stage = updateStage(.pauseMusic)
                try musicMonitor.pause()
                didPause = true
                playbackState = .paused
                try await Task<Never, Never>.sleep(nanoseconds: 450_000_000)
            } else {
                if musicWasPlaying {
                    stage = updateStage(.pauseMusic)
                    try musicMonitor.pause()
                    didPause = true
                    playbackState = .paused
                    try await Task<Never, Never>.sleep(nanoseconds: 650_000_000)
                }
                if let fallback {
                    stage = updateStage(.routeAway)
                    try audioManager.setDefaultOutputDevice(fallback.id)
                    mustRestoreOutputRoute = true
                    try await waitForDefaultOutputDevice(fallback.id, timeout: 2.0)
                    actualOutputDeviceUID = fallback.uid
                    try await Task<Never, Never>.sleep(nanoseconds: 450_000_000)
                }
            }

            stage = updateStage(.writeRate)
            let lockStartedAt = Date()
            try audioManager.setSampleRate(rate, for: device)

            // Observe until the new rate stays stable instead of trusting one instant read.
            stage = updateStage(.waitDAC)
            let confirmedRate = try await waitForStableSampleRate(
                rate,
                device: device,
                timeout: max(0.5, dacLockDelaySeconds) + 0.25,
                stableFor: 0.25
            )

            // Nominal rate can update before USB hardware is ready to accept a new
            // stream. Honour the configured lock wait as a minimum idle interval.
            let remainingLockWait = dacLockDelaySeconds - Date().timeIntervalSince(lockStartedAt)
            if remainingLockWait > 0 {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(remainingLockWait * 1_000_000_000)
                )
            }

            if mustRestoreOutputRoute {
                if playWhenFinished, let fallback {
                    // Start a muted stream on the fallback first, then move that live
                    // stream to the DAC. This reproduces the manual output-device
                    // switch that reliably wakes the WALKMAN after a clock change.
                    stage = updateStage(.resumeMusic)
                    try musicMonitor.play()
                    didPause = false
                    resumedOnFallback = true
                    playbackState = .playing
                    try await waitForDeviceToStartRunning(fallback.id, timeout: 2.0)
                    try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                }

                stage = updateStage(.routeBack)
                try audioManager.setDefaultOutputDevice(device.id)
                try await waitForDefaultOutputDevice(device.id, timeout: 2.0)
                actualOutputDeviceUID = device.uid
                mustRestoreOutputRoute = false
                if resumedOnFallback {
                    try await waitForDeviceToStartRunning(device.id, timeout: 2.5)
                } else {
                    try await Task<Never, Never>.sleep(nanoseconds: 450_000_000)
                }
            }

            if playWhenFinished {
                if !resumedOnFallback {
                    stage = updateStage(.resumeMusic)
                    try musicMonitor.play()
                    didPause = false
                    playbackState = .playing
                }

                // A longer stable window catches devices that briefly report the target
                // rate and then fall back while Music recreates its output stream.
                stage = updateStage(.verifyOutput)
                let postResumeRate = try await waitForStableSampleRate(
                    rate,
                    device: device,
                    timeout: max(1.5, dacLockDelaySeconds + 0.6),
                    stableFor: 0.6
                )
                try await waitForDeviceToStartRunning(device.id, timeout: 1.5)
                deviceSampleRate = postResumeRate
                playbackState = .playing

                if musicIsTemporarilyMuted, let originalMusicVolume {
                    try musicMonitor.setSoundVolume(originalMusicVolume)
                    musicIsTemporarilyMuted = false
                }
            } else {
                deviceSampleRate = confirmedRate
            }

            lastAppliedTrackID = trackID
            nextRetryDate = nil
            diagnosticText = nil
            statusText = playWhenFinished ? text(.matchedPlaying) : text(.prematched)
        } catch {
            scheduleRetry(afterFailureAt: stage, error: error)
        }
    }

    private func switchOutputDevice(to device: AudioDevice) async {
        var needsResume = false
        var stage = text(.prepareOutputSwitch)

        defer {
            if needsResume {
                try? musicMonitor.play()
                playbackState = .playing
            }
            isSwitching = false
        }

        do {
            let snapshot = try musicMonitor.snapshot()
            let currentTrack = snapshot.track ?? track
            let wasPlaying = snapshot.state == .playing

            if wasPlaying {
                stage = updateStage(.pauseMusic)
                try musicMonitor.pause()
                needsResume = true
                playbackState = .paused

                // Let Music release the stream owned by the previous output device.
                try await Task<Never, Never>.sleep(nanoseconds: 650_000_000)
            }

            stage = updateStage(.switchSystemOutput)
            try audioManager.setDefaultOutputDevice(device.id)

            stage = updateStage(.confirmSystemOutput)
            try await waitForDefaultOutputDevice(device.id, timeout: 2.0)
            actualOutputDeviceUID = device.uid
            selectedDeviceUID = device.uid

            // Give macOS time to publish the new route before configuring its clock.
            try await Task<Never, Never>.sleep(nanoseconds: 350_000_000)

            if let currentTrack, currentTrack.sampleRate > 0 {
                stage = updateStage(.writeNewRate)
                let currentRate = try audioManager.currentSampleRate(for: device.id)
                if abs(currentRate - currentTrack.sampleRate) >= 1 {
                    try audioManager.setSampleRate(currentTrack.sampleRate, for: device)
                }

                stage = updateStage(.waitNewStable)
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
                stage = updateStage(.resumeOnNew)
                try musicMonitor.play()
                needsResume = false
                playbackState = .playing

                stage = updateStage(.confirmNewStream)
                do {
                    try await waitForDeviceToStartRunning(device.id, timeout: 1.2)
                } catch {
                    // The route and clock can look correct while Music still owns a
                    // stale stream. Reopen it once before reporting success.
                    stage = updateStage(.rebuildNewStream)
                    try musicMonitor.pause()
                    needsResume = true
                    playbackState = .paused
                    try await Task<Never, Never>.sleep(nanoseconds: 450_000_000)
                    try musicMonitor.play()
                    needsResume = false
                    playbackState = .playing
                    try await waitForDeviceToStartRunning(device.id, timeout: 1.5)
                }
            }

            switchAttemptsForTrack = 0
            nextRetryDate = nil
            diagnosticText = nil
            statusText = wasPlaying
                ? text(.switchedPlaying, device.name)
                : text(.systemSwitched, device.name)
            refreshDevices()
        } catch {
            diagnosticText = "\(stage)：\(error.localizedDescription)"
            statusText = text(.switchFailed, device.name)
        }
    }

    private func rebuildAudioStream(automatic: Bool = false) async {
        var needsResume = false
        var targetDevice: AudioDevice?
        var mustRestoreOutputRoute = false
        var originalMusicVolume: Int?
        var musicIsTemporarilyMuted = false
        var resumedOnFallback = false
        defer {
            if mustRestoreOutputRoute, let targetDevice {
                try? audioManager.setDefaultOutputDevice(targetDevice.id)
                actualOutputDeviceUID = targetDevice.uid
            }
            if needsResume {
                try? musicMonitor.play()
                playbackState = .playing
            }
            if musicIsTemporarilyMuted, let originalMusicVolume {
                try? musicMonitor.setSoundVolume(originalMusicVolume)
            }
            isSwitching = false
        }

        do {
            guard let device = actualOutputDevice ?? selectedDevice else {
                throw CoreAudioError.propertyUnavailable(text(.selectDAC))
            }
            targetDevice = device
            let snapshot = try musicMonitor.snapshot()
            let wasPlaying = snapshot.state == .playing || playbackState == .playing
            let fallback = device.requiresRouteReset
                ? fallbackOutputDevice(excluding: device)
                : nil

            if device.requiresRouteReset, fallback == nil {
                throw CoreAudioError.propertyUnavailable(text(.noFallbackOutput))
            }

            if wasPlaying, let fallback {
                originalMusicVolume = try musicMonitor.soundVolume()
                if originalMusicVolume != 0 {
                    try musicMonitor.setSoundVolume(0)
                    musicIsTemporarilyMuted = true
                }

                statusText = text(.routeAway)
                try audioManager.setDefaultOutputDevice(fallback.id)
                mustRestoreOutputRoute = true
                try await waitForDefaultOutputDevice(fallback.id, timeout: 2.0)
                actualOutputDeviceUID = fallback.uid
                try await waitForDeviceToStartRunning(fallback.id, timeout: 2.0)
                try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)

                statusText = text(.pauseMusic)
                try musicMonitor.pause()
                needsResume = true
                playbackState = .paused
                try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            } else {
                if wasPlaying {
                    statusText = text(.pauseMusic)
                    try musicMonitor.pause()
                    needsResume = true
                    playbackState = .paused
                    try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
                }
                if let fallback {
                    statusText = text(.routeAway)
                    try audioManager.setDefaultOutputDevice(fallback.id)
                    mustRestoreOutputRoute = true
                    try await waitForDefaultOutputDevice(fallback.id, timeout: 2.0)
                    actualOutputDeviceUID = fallback.uid
                    try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
                }
            }

            let sourceRate = track?.sampleRate ?? 0
            let targetRate = sourceRate > 0
                ? sourceRate
                : try audioManager.currentSampleRate(for: device.id)
            var currentRate = try audioManager.currentSampleRate(for: device.id)
            var targetLockStartedAt = Date()
            if device.requiresRouteReset,
               abs(currentRate - targetRate) < 1,
               let relockRate = RateMatcher.relockRate(
                   for: targetRate,
                   availableRates: device.availableSampleRates
               ) {
                statusText = text(.writeRate)
                try audioManager.setSampleRate(relockRate, for: device)
                _ = try await waitForStableSampleRate(
                    relockRate,
                    device: device,
                    timeout: max(1.0, dacLockDelaySeconds) + 0.5,
                    stableFor: 0.3
                )
                currentRate = relockRate
            }
            if abs(currentRate - targetRate) >= 1 {
                statusText = text(.writeRate)
                targetLockStartedAt = Date()
                try audioManager.setSampleRate(targetRate, for: device)
            }
            statusText = text(.waitDAC)
            deviceSampleRate = try await waitForStableSampleRate(
                targetRate,
                device: device,
                timeout: max(1.0, dacLockDelaySeconds) + 0.5,
                stableFor: 0.4
            )
            let remainingLockWait = dacLockDelaySeconds - Date().timeIntervalSince(targetLockStartedAt)
            if remainingLockWait > 0 {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(remainingLockWait * 1_000_000_000)
                )
            }

            if mustRestoreOutputRoute {
                if wasPlaying, let fallback {
                    statusText = text(.resumeMusic)
                    try musicMonitor.play()
                    needsResume = false
                    resumedOnFallback = true
                    playbackState = .playing
                    try await waitForDeviceToStartRunning(fallback.id, timeout: 2.0)
                    try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
                }

                statusText = text(.routeBack)
                try audioManager.setDefaultOutputDevice(device.id)
                try await waitForDefaultOutputDevice(device.id, timeout: 2.0)
                actualOutputDeviceUID = device.uid
                mustRestoreOutputRoute = false
                if resumedOnFallback {
                    try await waitForDeviceToStartRunning(device.id, timeout: 2.5)
                } else {
                    try await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
                }
            }

            if wasPlaying {
                if !resumedOnFallback {
                    statusText = text(.resumeMusic)
                    try musicMonitor.play()
                    needsResume = false
                    playbackState = .playing
                }
                try await waitForDeviceToStartRunning(device.id, timeout: 1.5)

                if musicIsTemporarilyMuted, let originalMusicVolume {
                    try musicMonitor.setSoundVolume(originalMusicVolume)
                    musicIsTemporarilyMuted = false
                }
            }

            lastAppliedTrackID = track?.persistentID
            switchAttemptsForTrack = 0
            nextRetryDate = nil
            statusText = text(.streamRefreshed)
            diagnosticText = nil
        } catch {
            if automatic {
                scheduleRetry(afterFailureAt: text(.rebuildingStream), error: error)
            } else {
                diagnosticText = "重建音频流：\(error.localizedDescription)"
                statusText = text(.recoveryFailed)
            }
        }
    }

    private func fallbackOutputDevice(excluding target: AudioDevice) -> AudioDevice? {
        let alternatives = devices.filter { $0.id != target.id }
        return alternatives.first(where: { !$0.requiresRouteReset }) ?? alternatives.first
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
            text(
                .waitRateTimeout,
                SampleRateFormatter.string(targetRate),
                SampleRateFormatter.string(lastObservedRate)
            )
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
        throw CoreAudioError.propertyUnavailable(text(.defaultNotConfirmed))
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
        throw CoreAudioError.propertyUnavailable(text(.streamNotDetected))
    }

    private func scheduleRetry(afterFailureAt stage: String, error: Error) {
        diagnosticText = "\(stage)：\(error.localizedDescription)"
        guard switchAttemptsForTrack < maximumSwitchAttempts else {
            nextRetryDate = nil
            statusText = text(.retryPaused)
            return
        }

        let attemptIndex = Double(max(0, switchAttemptsForTrack - 1))
        let delay = min(pow(2.0, attemptIndex) * 0.5, 3.0)
        nextRetryDate = Date().addingTimeInterval(delay)
        statusText = text(.retryAfter, delay)
    }

    private func refreshDeviceRate() {
        guard let device = actualOutputDevice ?? selectedDevice else {
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

    private func refreshLiveOutputState() {
        guard let defaultID = try? audioManager.currentDefaultOutputDeviceID() else { return }
        if let actualDevice = devices.first(where: { $0.id == defaultID }) {
            actualOutputDeviceUID = actualDevice.uid
        }
        if let liveRate = try? audioManager.currentSampleRate(for: defaultID) {
            deviceSampleRate = liveRate
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
        if let data = try? musicMonitor.currentArtworkData(),
           let image = NSImage(data: data) {
            catalogArtworkTask?.cancel()
            catalogArtworkTask = nil
            artworkImage = image
            nextArtworkLoadDate = nil
            return
        }

        // Streaming tracks frequently expose no AppleScript artwork at all. Give
        // Music a brief chance to populate it, then fall back to Apple's public
        // catalog without blocking the polling or sample-rate switching path.
        guard artworkLoadAttempts >= 2,
              catalogArtworkRequestedTrackID != currentTrack.persistentID
        else { return }
        catalogArtworkRequestedTrackID = currentTrack.persistentID
        catalogArtworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.musicMonitor.catalogArtworkData(for: currentTrack)
            guard !Task.isCancelled,
                  self.artworkTrackID == currentTrack.persistentID,
                  let data,
                  let image = NSImage(data: data)
            else { return }
            self.artworkImage = image
            self.nextArtworkLoadDate = nil
            self.catalogArtworkTask = nil
        }
    }

    private func setError(_ error: Error) {
        let message = error.localizedDescription
        guard consecutiveErrorKey != message else { return }
        consecutiveErrorKey = message
        statusText = message
    }
}
