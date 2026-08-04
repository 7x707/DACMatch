import CoreAudio
import Testing
@testable import DACMatch

@Test func fixedRatesAreDiscoveredAndSorted() {
    let ranges = [
        AudioValueRange(mMinimum: 96_000, mMaximum: 96_000),
        AudioValueRange(mMinimum: 44_100, mMaximum: 44_100),
        AudioValueRange(mMinimum: 48_000, mMaximum: 48_000)
    ]
    #expect(RateMatcher.discreteRates(from: ranges) == [44_100, 48_000, 96_000])
}

@Test func continuousRangeSupportsCommonRates() {
    let ranges = [AudioValueRange(mMinimum: 44_100, mMaximum: 192_000)]
    #expect(RateMatcher.supports(88_200, ranges: ranges))
    #expect(!RateMatcher.supports(384_000, ranges: ranges))
    #expect(RateMatcher.discreteRates(from: ranges).contains(176_400))
}

@Test func sampleRateFormatting() {
    #expect(SampleRateFormatter.string(44_100) == "44.1 kHz")
    #expect(SampleRateFormatter.string(96_000) == "96 kHz")
}

@Test func relockRateChoosesNearestDifferentClock() {
    #expect(
        RateMatcher.relockRate(
            for: 48_000,
            availableRates: [44_100, 48_000, 96_000]
        ) == 44_100
    )
    #expect(RateMatcher.relockRate(for: 48_000, availableRates: [48_000]) == nil)
}

@Test func sameRateTrackDoesNotRefreshAudioStream() {
    #expect(!RateMatcher.needsSwitch(from: 44_100, to: 44_100))
    #expect(RateMatcher.needsSwitch(from: 44_100, to: 48_000))
}

@Test func availableRatesIdentifyUnsupportedSourceRate() {
    let rates = [44_100.0, 48_000.0, 96_000.0]
    #expect(RateMatcher.supports(48_000, availableRates: rates))
    #expect(!RateMatcher.supports(88_200, availableRates: rates))
}

@Test func pausedMusicSnapshotKeepsCurrentTrack() throws {
    let separator = String(UnicodeScalar(30))
    let value = ["paused", "TRACK-1", "Example", "Artist", "96000"]
        .joined(separator: separator)
    let snapshot = try MusicMonitor.parseSnapshot(value)

    #expect(snapshot.state == .paused)
    #expect(snapshot.track?.persistentID == "TRACK-1")
    #expect(snapshot.track?.sampleRate == 96_000)
}

@Test func musicSnapshotIncludesAlbumForArtworkMatching() throws {
    let separator = String(UnicodeScalar(30))
    let value = ["playing", "TRACK-ALBUM", "Example", "Artist", "Album", "44100"]
        .joined(separator: separator)
    let snapshot = try MusicMonitor.parseSnapshot(value)

    #expect(snapshot.track?.album == "Album")
    #expect(snapshot.track?.sampleRate == 44_100)
}

@Test func stoppedMusicSnapshotCanHaveNoTrack() throws {
    let snapshot = try MusicMonitor.parseSnapshot("stopped")
    #expect(snapshot.state == .stopped)
    #expect(snapshot.track == nil)
}

@Test func transitionalTrackMetadataIsRetainedWithoutSampleRate() throws {
    let separator = String(UnicodeScalar(30))
    let value = ["playing", "TRACK-2", "Loading Track", "Artist", "missing value"]
        .joined(separator: separator)
    let snapshot = try MusicMonitor.parseSnapshot(value)

    #expect(snapshot.state == .playing)
    #expect(snapshot.track?.persistentID == "TRACK-2")
    #expect(snapshot.track?.sampleRate == 0)
}

@Test func playingStateCanTemporarilyHaveNoTrackMetadata() throws {
    let snapshot = try MusicMonitor.parseSnapshot("playing")
    #expect(snapshot.state == .playing)
    #expect(snapshot.track == nil)
}

@Test func interfaceCopySupportsAllLanguages() {
    #expect(AppCopy.text(.rematch, language: .simplifiedChinese) == "重新匹配")
    #expect(AppCopy.text(.rematch, language: .traditionalChinese) == "重新匹配")
    #expect(AppCopy.text(.rematch, language: .english) == "Rematch")
}

@Test func localizedCopyFormatsValues() {
    #expect(
        AppCopy.text(
            .switchingTo,
            language: .english,
            arguments: ["WALKMAN"]
        ) == "Switching safely to WALKMAN…"
    )
}
