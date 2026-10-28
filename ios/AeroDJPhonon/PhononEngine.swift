import Foundation
import PhononTTS

/// On-device Phonon synthesis for the app target's `PhononSpeechProvider`.
///
/// This framework is iOS 18 and arm64 because `ptts` 0.5.0 is. The iOS 17 app
/// dlopens it only when that runtime is available. It does not construct
/// `PhononPlayer` and does not call `PhononModels.download`. Those are the
/// package APIs that start audio (`PhononPlayer`) or open a URL (`download`).
/// `Phonon.synthesize` returns PCM samples; the app encodes a WAV for the
/// existing interlude player.

private final class LoadBox: @unchecked Sendable {
    var code: Int32 = 2
    var model: Phonon?
    var samples: [Float]?
}

private final class PhononBox: @unchecked Sendable {
    static let shared = PhononBox()
    private let queue = DispatchQueue(label: "com.aerodj.phonon.engine")
    private var model: Phonon?

    func prepare(directory: String, voice: String) -> Int32 {
        queue.sync { load(directory, voice: voice) }
    }

    func synthesize(_ text: String, to path: String) -> Int32 {
        queue.sync { speak(text, path: path) }
    }

    private func load(_ directory: String, voice: String) -> Int32 {
        if model != nil { return 0 }
        let box = LoadBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let loaded = try await Phonon.load(
                    models: URL(fileURLWithPath: directory, isDirectory: true),
                    language: .english)
                if !loaded.voices.contains(voice) {
                    box.code = 3
                } else {
                    try await loaded.setVoice(voice)
                    box.model = loaded
                    box.code = 0
                }
            } catch {
                box.code = 2
            }
            sem.signal()
        }
        sem.wait()
        if box.code == 0 { model = box.model }
        return box.code
    }

    private func speak(_ text: String, path: String) -> Int32 {
        guard let model else { return 6 }
        let box = LoadBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let samples = try await model.synthesize(text)
                box.samples = samples
                box.code = samples.isEmpty ? 4 : 0
            } catch {
                box.code = 2
            }
            sem.signal()
        }
        sem.wait()
        guard box.code == 0, let samples = box.samples else { return box.code }
        let cleaned = samples.map { $0.isFinite ? $0 : 0 }
        let data = cleaned.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return 5
        }
        return 0
    }
}

@_cdecl("aerodj_phonon_prepare")
public func aerodj_phonon_prepare(_ directory: UnsafePointer<CChar>?, _ voice: UnsafePointer<CChar>?) -> Int32 {
    guard let directory, let voice else { return 6 }
    return PhononBox.shared.prepare(directory: String(cString: directory), voice: String(cString: voice))
}

@_cdecl("aerodj_phonon_synthesize")
public func aerodj_phonon_synthesize(_ text: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?) -> Int32 {
    guard let text, let path else { return 6 }
    return PhononBox.shared.synthesize(String(cString: text), to: String(cString: path))
}
