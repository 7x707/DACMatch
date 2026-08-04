import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum CopyKey: String, Sendable {
    case starting, switchingTo, rematching, rebuildingStream, noDAC
    case selectSong, noRate, autoPaused, selectDAC, matched, prematched, resampling
    case waitingRetry, outputMismatch, safeRateSwitch, preparingSwitch, pauseMusic
    case writeRate, waitDAC, resumeMusic, verifyOutput, matchedPlaying
    case prepareOutputSwitch, switchSystemOutput, confirmSystemOutput, writeNewRate
    case waitNewStable, resumeOnNew, confirmNewStream, rebuildNewStream
    case switchedPlaying, systemSwitched, switchFailed, streamRefreshed
    case recoveryFailed, waitRateTimeout, defaultNotConfirmed, streamNotDetected
    case retryPaused, retryAfter, waitingTrackInfo, connecting
    case rematch, recoverSound, quit, noTrack, unknownArtist, startAppleMusic
    case autoMatch, enabled, disabled, outputDevice, noDevices, rescan
    case launchAtLogin, language, playing, paused, appleMusic, currentDefault
}

enum AppCopy {
    static func text(
        _ key: CopyKey,
        language: AppLanguage,
        arguments: [CVarArg] = []
    ) -> String {
        let format = table[language]?[key] ?? table[.english]?[key] ?? key.rawValue
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    static func isSuccessStatus(_ text: String) -> Bool {
        ["已匹配", "预匹配", "已切换", "已刷新",
         "已匹配", "預先匹配", "已切換", "已刷新",
         "Matched", "Pre-matched", "Switched", "refreshed"].contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    static func isProgressStatus(_ text: String) -> Bool {
        ["正在", "准备", "等待", "重试", "载入", "连接",
         "正在", "準備", "等待", "重試", "載入", "連接",
         "Switching", "Preparing", "Waiting", "Retrying", "Rebuilding", "Loading", "Connecting"].contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    private static let table: [AppLanguage: [CopyKey: String]] = [
        .simplifiedChinese: [
            .starting: "正在启动…",
            .switchingTo: "正在安全切换到 %@…",
            .rematching: "正在重新匹配…",
            .rebuildingStream: "正在重建 Apple Music 音频流…",
            .noDAC: "未选择 DAC",
            .selectSong: "请在 Apple Music 中选择一首歌曲",
            .noRate: "当前曲目没有可用的采样率信息",
            .autoPaused: "自动匹配已暂停",
            .selectDAC: "请选择输出 DAC",
            .matched: "采样率已匹配",
            .prematched: "已预匹配，等待播放",
            .resampling: "DAC 不支持 %@，系统重采样为 %@",
            .waitingRetry: "等待自动重试…",
            .outputMismatch: "输出仍不匹配，请点“重新匹配”",
            .safeRateSwitch: "正在安全切换采样率…",
            .preparingSwitch: "准备切换",
            .pauseMusic: "暂停 Apple Music",
            .writeRate: "写入 DAC 采样率",
            .waitDAC: "等待 DAC 稳定锁定",
            .resumeMusic: "恢复 Apple Music",
            .verifyOutput: "验证恢复后的输出",
            .matchedPlaying: "采样率已匹配，正在播放",
            .prepareOutputSwitch: "准备切换输出设备",
            .switchSystemOutput: "切换系统输出设备",
            .confirmSystemOutput: "确认系统输出设备",
            .writeNewRate: "写入新设备采样率",
            .waitNewStable: "等待新设备稳定锁定",
            .resumeOnNew: "在新设备上恢复 Apple Music",
            .confirmNewStream: "确认新设备音频流",
            .rebuildNewStream: "重新建立新设备音频流",
            .switchedPlaying: "已切换到 %@，正在播放",
            .systemSwitched: "系统输出已切换到 %@",
            .switchFailed: "切换到 %@ 失败",
            .streamRefreshed: "音频流已刷新，请确认声音",
            .recoveryFailed: "恢复声音失败",
            .waitRateTimeout: "等待 %@ 超时，最后检测到 %@",
            .defaultNotConfirmed: "系统没有确认新的默认输出设备",
            .streamNotDetected: "新输出设备没有检测到音频流",
            .retryPaused: "自动重试已暂停，请手动重新匹配",
            .retryAfter: "匹配未稳定，%.1f 秒后重试",
            .waitingTrackInfo: "Apple Music 正在载入曲目信息…",
            .connecting: "正在连接 Apple Music…",
            .rematch: "重新匹配",
            .recoverSound: "恢复声音",
            .quit: "退出",
            .noTrack: "未选择曲目",
            .unknownArtist: "未知艺人",
            .startAppleMusic: "请在 Apple Music 中开始播放",
            .autoMatch: "自动匹配采样率",
            .enabled: "已开启",
            .disabled: "已关闭",
            .outputDevice: "输出设备",
            .noDevices: "没有找到输出设备",
            .rescan: "重新扫描",
            .launchAtLogin: "登录时启动",
            .language: "语言",
            .playing: "正在播放",
            .paused: "已暂停",
            .appleMusic: "Apple Music",
            .currentDefault: "（当前默认）",
        ],
        .traditionalChinese: [
            .starting: "正在啟動…",
            .switchingTo: "正在安全切換至 %@…",
            .rematching: "正在重新匹配…",
            .rebuildingStream: "正在重建 Apple Music 音訊串流…",
            .noDAC: "未選擇 DAC",
            .selectSong: "請在 Apple Music 中選擇一首歌曲",
            .noRate: "目前歌曲沒有可用的取樣率資訊",
            .autoPaused: "自動匹配已暫停",
            .selectDAC: "請選擇輸出 DAC",
            .matched: "取樣率已匹配",
            .prematched: "已預先匹配，等待播放",
            .resampling: "DAC 不支援 %@，系統重新取樣為 %@",
            .waitingRetry: "等待自動重試…",
            .outputMismatch: "輸出仍不匹配，請按「重新匹配」",
            .safeRateSwitch: "正在安全切換取樣率…",
            .preparingSwitch: "準備切換",
            .pauseMusic: "暫停 Apple Music",
            .writeRate: "寫入 DAC 取樣率",
            .waitDAC: "等待 DAC 穩定鎖定",
            .resumeMusic: "恢復 Apple Music",
            .verifyOutput: "驗證恢復後的輸出",
            .matchedPlaying: "取樣率已匹配，正在播放",
            .prepareOutputSwitch: "準備切換輸出裝置",
            .switchSystemOutput: "切換系統輸出裝置",
            .confirmSystemOutput: "確認系統輸出裝置",
            .writeNewRate: "寫入新裝置取樣率",
            .waitNewStable: "等待新裝置穩定鎖定",
            .resumeOnNew: "在新裝置上恢復 Apple Music",
            .confirmNewStream: "確認新裝置音訊串流",
            .rebuildNewStream: "重新建立新裝置音訊串流",
            .switchedPlaying: "已切換至 %@，正在播放",
            .systemSwitched: "系統輸出已切換至 %@",
            .switchFailed: "切換至 %@ 失敗",
            .streamRefreshed: "音訊串流已刷新，請確認聲音",
            .recoveryFailed: "恢復聲音失敗",
            .waitRateTimeout: "等待 %@ 逾時，最後偵測到 %@",
            .defaultNotConfirmed: "系統未確認新的預設輸出裝置",
            .streamNotDetected: "新輸出裝置未偵測到音訊串流",
            .retryPaused: "自動重試已暫停，請手動重新匹配",
            .retryAfter: "匹配未穩定，%.1f 秒後重試",
            .waitingTrackInfo: "Apple Music 正在載入歌曲資訊…",
            .connecting: "正在連接 Apple Music…",
            .rematch: "重新匹配",
            .recoverSound: "恢復聲音",
            .quit: "結束",
            .noTrack: "未選擇歌曲",
            .unknownArtist: "未知藝人",
            .startAppleMusic: "請在 Apple Music 中開始播放",
            .autoMatch: "自動匹配取樣率",
            .enabled: "已開啟",
            .disabled: "已關閉",
            .outputDevice: "輸出裝置",
            .noDevices: "找不到輸出裝置",
            .rescan: "重新掃描",
            .launchAtLogin: "登入時啟動",
            .language: "語言",
            .playing: "正在播放",
            .paused: "已暫停",
            .appleMusic: "Apple Music",
            .currentDefault: "（目前預設）",
        ],
        .english: [
            .starting: "Starting…",
            .switchingTo: "Switching safely to %@…",
            .rematching: "Rematching…",
            .rebuildingStream: "Rebuilding the Apple Music audio stream…",
            .noDAC: "No DAC selected",
            .selectSong: "Select a song in Apple Music",
            .noRate: "No sample-rate information is available for this track",
            .autoPaused: "Automatic matching is paused",
            .selectDAC: "Select an output DAC",
            .matched: "Sample rate matched",
            .prematched: "Pre-matched, waiting for playback",
            .resampling: "DAC doesn't support %@; macOS is resampling to %@",
            .waitingRetry: "Waiting to retry automatically…",
            .outputMismatch: "Output still does not match; choose Rematch",
            .safeRateSwitch: "Switching sample rate safely…",
            .preparingSwitch: "Preparing to switch",
            .pauseMusic: "Pausing Apple Music",
            .writeRate: "Applying the DAC sample rate",
            .waitDAC: "Waiting for the DAC to lock",
            .resumeMusic: "Resuming Apple Music",
            .verifyOutput: "Verifying output after resume",
            .matchedPlaying: "Sample rate matched, playing",
            .prepareOutputSwitch: "Preparing to switch output device",
            .switchSystemOutput: "Switching the system output device",
            .confirmSystemOutput: "Confirming the system output device",
            .writeNewRate: "Applying the new device sample rate",
            .waitNewStable: "Waiting for the new device to lock",
            .resumeOnNew: "Resuming Apple Music on the new device",
            .confirmNewStream: "Checking the new device audio stream",
            .rebuildNewStream: "Rebuilding the new device audio stream",
            .switchedPlaying: "Switched to %@, playing",
            .systemSwitched: "System output switched to %@",
            .switchFailed: "Could not switch to %@",
            .streamRefreshed: "Audio stream refreshed; check the sound",
            .recoveryFailed: "Could not restore sound",
            .waitRateTimeout: "Timed out waiting for %@; last detected %@",
            .defaultNotConfirmed: "The system did not confirm the new default output device",
            .streamNotDetected: "No audio stream was detected on the new output device",
            .retryPaused: "Automatic retries paused; rematch manually",
            .retryAfter: "Match is unstable; retrying in %.1f seconds",
            .waitingTrackInfo: "Apple Music is loading track information…",
            .connecting: "Connecting to Apple Music…",
            .rematch: "Rematch",
            .recoverSound: "Restore Sound",
            .quit: "Quit",
            .noTrack: "No Track Selected",
            .unknownArtist: "Unknown Artist",
            .startAppleMusic: "Start playback in Apple Music",
            .autoMatch: "Match Sample Rate",
            .enabled: "On",
            .disabled: "Off",
            .outputDevice: "Output Device",
            .noDevices: "No output devices found",
            .rescan: "Rescan",
            .launchAtLogin: "Launch at Login",
            .language: "Language",
            .playing: "Playing",
            .paused: "Paused",
            .appleMusic: "Apple Music",
            .currentDefault: " (Current)",
        ]
    ]
}
