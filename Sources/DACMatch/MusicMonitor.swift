import Foundation

struct MusicTrack: Equatable, Sendable {
    let persistentID: String
    let name: String
    let artist: String
    let sampleRate: Double
}

enum MusicMonitorError: LocalizedError {
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message): return "无法读取 Apple Music：\(message)"
        case .invalidResponse: return "Apple Music 返回了无法识别的曲目信息"
        }
    }
}

struct MusicMonitor {
    private static let script = """
    tell application "Music"
        if player state is not playing then return ""
        set currentItem to current track
        set trackID to persistent ID of currentItem as text
        set trackName to name of currentItem as text
        set trackArtist to artist of currentItem as text
        set trackRate to sample rate of currentItem as text
        return trackID & (ASCII character 30) & trackName & (ASCII character 30) & trackArtist & (ASCII character 30) & trackRate
    end tell
    """

    func currentTrack() throws -> MusicTrack? {
        guard let appleScript = NSAppleScript(source: Self.script) else {
            throw MusicMonitorError.scriptFailed("无法创建自动化脚本")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }

        guard let value = result.stringValue else { throw MusicMonitorError.invalidResponse }
        if value.isEmpty { return nil }

        let fields = value.components(separatedBy: String(UnicodeScalar(30)))
        guard fields.count == 4, let rate = Double(fields[3]) else {
            throw MusicMonitorError.invalidResponse
        }
        return MusicTrack(
            persistentID: fields[0],
            name: fields[1],
            artist: fields[2],
            sampleRate: rate
        )
    }

    func pause() throws {
        try runCommand("tell application \"Music\" to pause")
    }

    func play() throws {
        try runCommand("tell application \"Music\" to play")
    }

    private func runCommand(_ source: String) throws {
        guard let appleScript = NSAppleScript(source: source) else {
            throw MusicMonitorError.scriptFailed("无法创建自动化脚本")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }
    }
}
