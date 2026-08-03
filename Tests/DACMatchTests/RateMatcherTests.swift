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
