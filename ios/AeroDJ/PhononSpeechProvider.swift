import AeroDJCore
import Darwin
import Foundation
import os

/// True on iOS 18 arm64, which is the runtime `ptts` 0.5.0 documents.
/// `canImport(PhononTTS)` is false in this target: the package requires iOS 18,
/// and the app deployment target stays 17.0. The only `import PhononTTS` is in
/// the embedded AeroDJPhonon framework, loaded below when `isAvailable` is true.
enum PhononSpeechRuntime {
    static var isAvailable: Bool {
        #if arch(arm64)
        if #available(iOS 18, *) { return true }
        #endif
        return false
    }
}

enum PhononSpeechFailure: Error, CustomStringConvertible {
    case unsupportedRuntime
    case notReady(PhononModelStatus)
    case engine(Int32)

    var description: String {
        switch self {
        case .unsupportedRuntime: return "phonon.unsupportedRuntime"
        case .notReady(let status): return "phonon.\(status.rawValue)"
        case .engine(let code): return "phonon.engine.\(code)"
        }
    }
}

/// One more `VoiceProvider` in the existing `VoiceRenderer` chain. It renders a
/// break to WAV bytes. It does not play them, and it does not configure the
/// audio session. When the model is missing, mismatched, or failed, `synthesize`
/// throws and the renderer continues to `OnDeviceSpeechProvider`.
struct PhononSpeechProvider: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        guard PhononSpeechRuntime.isAvailable else { throw PhononSpeechFailure.unsupportedRuntime }
        let status = await PhononModelCoordinator.shared.status()
        guard status == .ready else { throw PhononSpeechFailure.notReady(status) }
        guard #available(iOS 18, *) else { throw PhononSpeechFailure.unsupportedRuntime }
        let samples = try await PhononEngineClient.synthesize(text)
        let wav = PhononWAV.encodePCM16(samples: samples)
        guard let seconds = PhononWAV.durationSeconds(wav: wav), seconds > 0, !wav.isEmpty else {
            throw PhononSpeechFailure.engine(4)
        }
        return VoiceArtifact(data: wav, durationSeconds: seconds, billableUnits: 0,
                             provider: PhononModelPin.providerID, cacheKey: nil)
    }
}

enum PhononSpeechRoutes {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "phonon")

    /// The engine framework is not embedded. Without it, dlopen cannot succeed,
    /// so the route list stays AVSpeech only.
    private static var frameworkBinaryExists: Bool {
        guard let base = Bundle.main.privateFrameworksURL else { return false }
        let binary = base.appendingPathComponent("AeroDJPhonon.framework/AeroDJPhonon")
        return FileManager.default.fileExists(atPath: binary.path)
    }

    static func make() -> [VoiceRoute] {
        let decision = PhononSpeechSelection.decide(
            flagEnabled: PhononSpeechSelection.isFlagEnabled(),
            runtimeAvailable: PhononSpeechRuntime.isAvailable,
            model: .missing)
        let ids = decision.providerIDs.filter { id in
            id != PhononModelPin.providerID || frameworkBinaryExists
        }
        if ids.contains(PhononModelPin.providerID) {
            log.info("phonon enabled=true providers=\(ids.count, privacy: .public)")
        }
        return ids.map { id in
            if id == PhononModelPin.providerID {
                return VoiceRoute(providerID: id, provider: PhononSpeechProvider(),
                                  voice: VoiceProfile(id: PhononModelPin.voiceID, name: PhononModelPin.voiceID),
                                  microdollarsPerThousandCharacters: 0, timeout: .seconds(20), acceptsSSML: false)
            }
            return .onDevice()
        }
    }
}

@available(iOS 18, *)
enum PhononEngineClient {
    private static let loader = Loader()

    static func prepare(directory: String, voice: String) async -> Int32 {
        guard let fn = loader.function(kind: .prepare) else { return 2 }
        return await onBackgroundQueue {
            directory.withCString { dir in voice.withCString { name in fn(dir, name) } }
        }
    }

    static func synthesize(_ text: String) async throws -> [Float] {
        try await SpeechTempFiles.shared.withFile { url in
            guard let fn = loader.function(kind: .synthesize) else { throw PhononSpeechFailure.engine(2) }
            let code = await onBackgroundQueue {
                text.withCString { cue in url.path.withCString { path in fn(cue, path) } }
            }
            guard code == 0 else { throw PhononSpeechFailure.engine(code) }
            let data = try Data(contentsOf: url)
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0, data.count == count * MemoryLayout<Float>.size else {
                throw PhononSpeechFailure.engine(4)
            }
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return samples
        }
    }

    private static func onBackgroundQueue(_ body: @escaping () -> Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }

    private typealias Entry = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32

    private final class Loader: @unchecked Sendable {
        enum Kind { case prepare, synthesize }
        private let lock = NSLock()
        private var opened = false
        private var prepareFn: Entry?
        private var synthFn: Entry?

        func function(kind: Kind) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            if !opened { openLocked() }
            switch kind {
            case .prepare: return prepareFn
            case .synthesize: return synthFn
            }
        }

        private func openLocked() {
            opened = true
            guard let base = Bundle.main.privateFrameworksURL else { return }
            let binary = base.appendingPathComponent("AeroDJPhonon.framework/AeroDJPhonon").path
            guard let handle = dlopen(binary, RTLD_NOW | RTLD_LOCAL),
                  let prepareSym = dlsym(handle, "aerodj_phonon_prepare"),
                  let synthSym = dlsym(handle, "aerodj_phonon_synthesize") else { return }
            prepareFn = unsafeBitCast(prepareSym, to: Entry.self)
            synthFn = unsafeBitCast(synthSym, to: Entry.self)
        }
    }
}
