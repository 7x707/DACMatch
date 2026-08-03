import Foundation

struct MusicTrack: Equatable, Sendable {
    let persistentID: String
    let name: String
    let artist: String
    let sampleRate: Double
}

enum MusicPlaybackState: String, Sendable {
    case playing
    case paused
    case stopped
}

struct MusicPlaybackSnapshot: Sendable {
    let state: MusicPlaybackState
    let track: MusicTrack?
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
        if player state is playing then
            set stateText to "playing"
        else if player state is paused then
            set stateText to "paused"
        else
            set stateText to "stopped"
        end if

        try
            set currentItem to current track
            set trackID to persistent ID of currentItem as text
            set trackName to name of currentItem as text
            set trackArtist to artist of currentItem as text
            set trackRate to sample rate of currentItem as text
            return stateText & (ASCII character 30) & trackID & (ASCII character 30) & trackName & (ASCII character 30) & trackArtist & (ASCII character 30) & trackRate
        on error
            return stateText
        end try
    end tell
    """

    private static let artworkScript = """
    tell application "Music"
        try
            set currentItem to current track
            if (count of artworks of currentItem) is 0 then return missing value
            return raw data of artwork 1 of currentItem
        on error
            return missing value
        end try
    end tell
    """

    func snapshot() throws -> MusicPlaybackSnapshot {
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
        return try Self.parseSnapshot(value)
    }

    static func parseSnapshot(_ value: String) throws -> MusicPlaybackSnapshot {
        let fields = value.components(separatedBy: String(UnicodeScalar(30)))
        guard let state = MusicPlaybackState(rawValue: fields[0]) else {
            throw MusicMonitorError.invalidResponse
        }
        guard fields.count > 1 else {
            return MusicPlaybackSnapshot(state: state, track: nil)
        }
        guard fields.count == 5, let rate = Double(fields[4]) else {
            throw MusicMonitorError.invalidResponse
        }
        return MusicPlaybackSnapshot(
            state: state,
            track: MusicTrack(
                persistentID: fields[1],
                name: fields[2],
                artist: fields[3],
                sampleRate: rate
            )
        )
    }

    func currentArtworkData() throws -> Data? {
        guard let appleScript = NSAppleScript(source: Self.artworkScript) else {
            throw MusicMonitorError.scriptFailed("无法创建封面读取脚本")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }

        guard result.descriptorType != typeNull else { return nil }
        return result.data
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
