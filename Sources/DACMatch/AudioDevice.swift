import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let availableSampleRates: [Double]
    let isDefaultOutput: Bool

    var displayName: String {
        isDefaultOutput ? "\(name)（当前默认）" : name
    }

}

enum CoreAudioError: LocalizedError {
    case propertyUnavailable(String)
    case osStatus(OSStatus, String)
    case unsupportedRate(Double)

    var errorDescription: String? {
        switch self {
        case .propertyUnavailable(let property):
            return "无法读取音频属性：\(property)"
        case .osStatus(let status, let operation):
            return "\(operation)失败（Core Audio \(status)）"
        case .unsupportedRate(let rate):
            return "DAC 不支持 \(SampleRateFormatter.string(rate))"
        }
    }
}

struct CoreAudioDeviceManager: Sendable {
    func outputDevices() throws -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size),
            "读取音频设备列表"
        )

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        try check(
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids),
            "读取音频设备列表"
        )

        let defaultID = try? currentDefaultOutputDeviceID()
        return ids.compactMap { id in
            guard hasOutputStreams(id),
                  let uid = try? stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = try? stringProperty(id, kAudioObjectPropertyName)
            else { return nil }

            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                transportType: (try? uint32Property(id, kAudioDevicePropertyTransportType)) ?? 0,
                availableSampleRates: (try? availableSampleRates(for: id)) ?? [],
                isDefaultOutput: id == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefaultOutput != rhs.isDefaultOutput { return lhs.isDefaultOutput }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func currentSampleRate(for deviceID: AudioObjectID) throws -> Double {
        var address = nominalSampleRateAddress
        var rate = Double.zero
        var size = UInt32(MemoryLayout<Double>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate),
            "读取 DAC 采样率"
        )
        return rate
    }

    func setSampleRate(_ rate: Double, for device: AudioDevice) throws {
        guard RateMatcher.supports(rate, ranges: try availableSampleRateRanges(for: device.id)) else {
            throw CoreAudioError.unsupportedRate(rate)
        }

        var address = nominalSampleRateAddress
        var settable = DarwinBoolean(false)
        try check(
            AudioObjectIsPropertySettable(device.id, &address, &settable),
            "检查 DAC 采样率写入权限"
        )
        guard settable.boolValue else {
            throw CoreAudioError.propertyUnavailable("设备不允许修改采样率")
        }

        var newRate = rate
        try check(
            AudioObjectSetPropertyData(
                device.id,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Double>.size),
                &newRate
            ),
            "设置 DAC 采样率"
        )
    }

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newDefault = deviceID
        try check(
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioObjectID>.size),
                &newDefault
            ),
            "切换系统输出设备"
        )

        // macOS Sound settings updates both selectors. Mirroring that behavior
        // makes the programmatic handoff indistinguishable from a user selecting
        // another output in Control Centre, including for apps watching the system
        // output route rather than only the regular default output route.
        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newSystemDefault = deviceID
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &newSystemDefault
        )
    }

    func currentDefaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &id
            ),
            "读取默认输出设备"
        )
        return id
    }

    func isDeviceRunning(_ deviceID: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning),
            "检查输出设备音频流"
        )
        return isRunning != 0
    }

    private var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func stringProperty(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
            },
            "读取设备名称"
        )
        return value as String
    }

    private func uint32Property(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
            "读取设备连接类型"
        )
        return value
    }

    private func availableSampleRates(for deviceID: AudioObjectID) throws -> [Double] {
        RateMatcher.discreteRates(from: try availableSampleRateRanges(for: deviceID))
    }

    private func availableSampleRateRanges(for deviceID: AudioObjectID) throws -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            "读取 DAC 支持的采样率"
        )
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = Array(repeating: AudioValueRange(), count: count)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges),
            "读取 DAC 支持的采样率"
        )
        return ranges
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError.osStatus(status, operation) }
    }
}

enum RateMatcher {
    static let commonRates: [Double] = [
        8_000, 11_025, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
        352_800, 384_000, 705_600, 768_000
    ]

    static func supports(_ rate: Double, ranges: [AudioValueRange]) -> Bool {
        ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }

    static func needsSwitch(from currentRate: Double, to targetRate: Double) -> Bool {
        abs(currentRate - targetRate) >= 1
    }

    static func discreteRates(from ranges: [AudioValueRange]) -> [Double] {
        let rates = commonRates.filter { supports($0, ranges: ranges) }
        let fixedRates = ranges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum)
        return Array(Set(rates + fixedRates)).sorted()
    }

    static func relockRate(for targetRate: Double, availableRates: [Double]) -> Double? {
        availableRates
            .filter { abs($0 - targetRate) >= 1 }
            .min { abs($0 - targetRate) < abs($1 - targetRate) }
    }
}

enum SampleRateFormatter {
    static func string(_ rate: Double) -> String {
        if rate >= 1_000 {
            let khz = rate / 1_000
            return khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
        }
        return "\(Int(rate)) Hz"
    }
}
