import Foundation

/// 24 kHz mono 16-bit PCM WAV. Phonon returns Float32 at this rate. The existing
/// interlude player receives the encoded bytes; this type does not play them.
public enum PhononWAV {
    public static let sampleRate = 24_000
    /// Longer than a DJ break. A longer buffer is refused so the caller falls back.
    public static let maxSeconds = 60

    public static func encodePCM16(samples: [Float]) -> Data {
        let frames = samples.count
        guard frames > 0, frames <= sampleRate * maxSeconds else { return Data() }
        var data = Data(capacity: 44 + frames * 2)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        appendU32(UInt32(36 + frames * 2), to: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt 
        appendU32(16, to: &data)
        appendU16(1, to: &data) // PCM
        appendU16(1, to: &data) // mono
        appendU32(UInt32(sampleRate), to: &data)
        appendU32(UInt32(sampleRate * 2), to: &data)
        appendU16(2, to: &data)
        appendU16(16, to: &data)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        appendU32(UInt32(frames * 2), to: &data)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = min(1, max(-1, finite))
            let scaled = Int(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
            let bounded = min(Int(Int16.max), max(Int(Int16.min), scaled))
            var unit = Int16(bounded).littleEndian
            withUnsafeBytes(of: &unit) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Measured from the data chunk. Nil when the header is not the WAV this type writes.
    public static func durationSeconds(wav: Data) -> Double? {
        guard wav.count >= 44 else { return nil }
        let bytes = [UInt8](wav)
        guard bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) else { return nil }
        let rate = Int(u32(bytes, 24))
        let channels = Int(u16(bytes, 22))
        let bits = Int(u16(bytes, 34))
        guard rate == sampleRate, channels == 1, bits == 16 else { return nil }
        let dataBytes = Int(u32(bytes, 40))
        guard dataBytes > 0, dataBytes % 2 == 0, 44 + dataBytes <= wav.count else { return nil }
        return Double(dataBytes / 2) / Double(rate)
    }

    private static func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
