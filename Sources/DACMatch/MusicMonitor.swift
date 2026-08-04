import Foundation

struct MusicTrack: Equatable, Sendable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
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

final class MusicMonitor {
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
            set trackAlbum to album of currentItem as text
            set trackRate to sample rate of currentItem as text
            return stateText & (ASCII character 30) & trackID & (ASCII character 30) & trackName & (ASCII character 30) & trackArtist & (ASCII character 30) & trackAlbum & (ASCII character 30) & trackRate
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

    private static let sampleRateScript = """
    tell application "Music"
        try
            return sample rate of current track
        on error
            return 0
        end try
    end tell
    """

    private lazy var snapshotAppleScript = NSAppleScript(source: Self.script)
    private lazy var artworkAppleScript = NSAppleScript(source: Self.artworkScript)
    private lazy var pauseAppleScript = NSAppleScript(source: "tell application \"Music\" to pause")
    private lazy var playAppleScript = NSAppleScript(source: "tell application \"Music\" to play")
    private lazy var sampleRateAppleScript = NSAppleScript(source: Self.sampleRateScript)
    private var knownSampleRates: [String: Double] = [:]

    func snapshot() throws -> MusicPlaybackSnapshot {
        guard let appleScript = snapshotAppleScript else {
            throw MusicMonitorError.scriptFailed("无法创建自动化脚本")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }

        guard let value = result.stringValue else { throw MusicMonitorError.invalidResponse }
        let snapshot = try Self.parseSnapshot(value)
        guard let track = snapshot.track else { return snapshot }

        if track.sampleRate > 0 {
            knownSampleRates[track.persistentID] = track.sampleRate
            return snapshot
        }

        let recoveredRate = readCurrentSampleRate()
            ?? knownSampleRates[track.persistentID]
            ?? 0
        guard recoveredRate > 0 else { return snapshot }
        knownSampleRates[track.persistentID] = recoveredRate
        return MusicPlaybackSnapshot(
            state: snapshot.state,
            track: MusicTrack(
                persistentID: track.persistentID,
                name: track.name,
                artist: track.artist,
                album: track.album,
                sampleRate: recoveredRate
            )
        )
    }

    static func parseSnapshot(_ value: String) throws -> MusicPlaybackSnapshot {
        let fields = value.components(separatedBy: String(UnicodeScalar(30)))
        guard let state = MusicPlaybackState(rawValue: fields[0]) else {
            throw MusicMonitorError.invalidResponse
        }
        guard fields.count > 1 else {
            return MusicPlaybackSnapshot(state: state, track: nil)
        }
        guard (fields.count == 5 || fields.count == 6), !fields[1].isEmpty else {
            return MusicPlaybackSnapshot(state: state, track: nil)
        }
        // Apple Music can briefly return "missing value" or an empty sample rate
        // while changing streaming tracks. Keep the metadata and retry the rate on
        // the next poll instead of treating this transition frame as a disconnect.
        let album = fields.count == 6 ? fields[4] : ""
        let rate = Double(fields.last ?? "") ?? 0
        return MusicPlaybackSnapshot(
            state: state,
            track: MusicTrack(
                persistentID: fields[1],
                name: fields[2],
                artist: fields[3],
                album: album,
                sampleRate: rate
            )
        )
    }

    func currentArtworkData() throws -> Data? {
        guard let appleScript = artworkAppleScript else {
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

    @MainActor
    func catalogArtworkData(for track: MusicTrack) async -> Data? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: [track.artist, track.album, track.name].joined(separator: " ")),
            URLQueryItem(name: "country", value: "HK"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let search = try? JSONDecoder().decode(CatalogSearchResponse.self, from: data),
              let result = bestCatalogMatch(for: track, candidates: search.results),
              let artworkURL = enlargedArtworkURL(result.artworkUrl100),
              let (artworkData, artworkResponse) = try? await URLSession.shared.data(from: artworkURL),
              (artworkResponse as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return artworkData
    }

    func pause() throws {
        try runCommand(pauseAppleScript)
    }

    func play() throws {
        try runCommand(playAppleScript)
    }

    func playerPosition() throws -> Double {
        guard let appleScript = NSAppleScript(
            source: "tell application \"Music\" to return player position"
        ) else {
            throw MusicMonitorError.scriptFailed("无法创建播放位置脚本")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }
        return result.doubleValue
    }

    func setPlayerPosition(_ position: Double) throws {
        let value = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            position
        )
        try runCommand(NSAppleScript(source: "tell application \"Music\" to set player position to \(value)"))
    }

    private func runCommand(_ appleScript: NSAppleScript?) throws {
        guard let appleScript else {
            throw MusicMonitorError.scriptFailed("无法创建自动化脚本")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw MusicMonitorError.scriptFailed(message)
        }
    }

    private func readCurrentSampleRate() -> Double? {
        guard let appleScript = sampleRateAppleScript else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, result.doubleValue > 0 else { return nil }
        return result.doubleValue
    }

    private func bestCatalogMatch(
        for track: MusicTrack,
        candidates: [CatalogSearchResult]
    ) -> CatalogSearchResult? {
        let targetName = normalized(track.name)
        let targetArtist = normalized(track.artist)
        let targetAlbum = normalized(track.album)

        let scored = candidates.map { candidate -> (CatalogSearchResult, Int) in
            let name = normalized(candidate.trackName)
            let artist = normalized(candidate.artistName)
            let album = normalized(candidate.collectionName ?? "")
            var score = 0
            if name == targetName { score += 8 }
            else if name.contains(targetName) || targetName.contains(name) { score += 4 }
            if artist == targetArtist { score += 6 }
            else if artist.contains(targetArtist) || targetArtist.contains(artist) { score += 3 }
            if !targetAlbum.isEmpty {
                if album == targetAlbum { score += 7 }
                else if album.contains(targetAlbum) || targetAlbum.contains(album) { score += 3 }
            }
            return (candidate, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 8 else { return nil }
        return best.0
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func enlargedArtworkURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let enlarged = value.replacingOccurrences(
            of: #"\d+x\d+"#,
            with: "600x600",
            options: .regularExpression
        )
        return URL(string: enlarged)
    }
}

private struct CatalogSearchResponse: Decodable {
    let results: [CatalogSearchResult]
}

private struct CatalogSearchResult: Decodable {
    let trackName: String
    let artistName: String
    let collectionName: String?
    let artworkUrl100: String?
}
