import Foundation

/// Why a voice route did not produce the clip.
public enum VoiceAttemptResult: Equatable, Sendable {
    case rendered
    case cacheHit
    case overCostCap
    case timedOut
    case failed(String)
    case invalidAudio
    case overDuration(Double)
    /// The caller cancelled; any reservation was released.
    case cancelled
}

public struct VoiceAttempt: Equatable, Sendable {
    public let providerID: String
    public let result: VoiceAttemptResult
}

public enum VoiceRenderError: Error, Equatable, Sendable {
    case timedOut
    case notImplemented(String)
    case invalidResponse(String)
    case insecureEndpoint
}

/// One provider in the fallback chain, in preference order.
public struct VoiceRoute: Sendable {
    public let providerID: String
    public let provider: any VoiceProvider
    public let voice: VoiceProfile
    /// Paid routes need a budget reservation before every call.
    public let microdollarsPerThousandCharacters: Int
    public let timeout: Duration
    /// Send SSML (`<speak>…`) instead of plain text.
    public let acceptsSSML: Bool

    public var isPaid: Bool { microdollarsPerThousandCharacters > 0 }

    public init(providerID: String, provider: any VoiceProvider, voice: VoiceProfile,
                microdollarsPerThousandCharacters: Int = 0, timeout: Duration = .seconds(8), acceptsSSML: Bool = false) {
        self.providerID = providerID
        self.provider = provider
        self.voice = voice
        self.microdollarsPerThousandCharacters = microdollarsPerThousandCharacters
        self.timeout = timeout
        self.acceptsSSML = acceptsSSML
    }

    func cost(characters: Int) -> Int {
        (characters * microdollarsPerThousandCharacters + 999) / 1000
    }
}

/// Per-user, per-local-day spend cap for paid voices, in microdollars.
/// Admission is an atomic reservation of the worst-case cost *before* the
/// call, so one call or concurrent calls cannot overrun the cap. Optional file
/// persistence keeps the day's spend across relaunch.
///
/// This is client-side defense in depth. The voice proxy must enforce the
/// same cap server-side; a client meter is not billing control.
public actor VoiceBudget {
    public struct Reservation: Hashable, Sendable {
        let id = UUID()
        let userID: String
        let day: String
        let microdollars: Int
    }

    private struct State: Codable {
        var day: String
        var spent: [String: Int]
    }

    public let dailyCapMicrodollars: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let file: URL?
    private var state: State
    private var held: [Reservation: Int] = [:]

    public init(dailyCapMicrodollars: Int, calendar: Calendar = .current, file: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.dailyCapMicrodollars = dailyCapMicrodollars
        self.calendar = calendar
        self.now = now
        self.file = file
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = loaded ?? State(day: "", spent: [:])
    }

    private func today() -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func rollover() {
        let day = today()
        if state.day != day { state = State(day: day, spent: [:]) }
    }

    /// Committed plus in-flight spend for `userID` today.
    public func committed(userID: String) -> Int {
        rollover()
        return state.spent[userID, default: 0]
    }

    private func inFlight(_ userID: String) -> Int {
        held.filter { $0.key.userID == userID && $0.key.day == state.day }.values.reduce(0, +)
    }

    /// Nil when the reservation would exceed the cap (hard stop).
    public func reserve(userID: String, microdollars: Int) -> Reservation? {
        rollover()
        guard microdollars >= 0,
              state.spent[userID, default: 0] + inFlight(userID) + microdollars <= dailyCapMicrodollars else { return nil }
        let r = Reservation(userID: userID, day: state.day, microdollars: microdollars)
        held[r] = microdollars
        return r
    }

    /// Charges the actual cost (never more than reserved is assumed safe;
    /// a larger actual is still charged so later calls stop).
    public func commit(_ r: Reservation, microdollars: Int) {
        guard held.removeValue(forKey: r) != nil else { return }
        rollover()
        if r.day == state.day { state.spent[r.userID, default: 0] += microdollars }
        persist()
    }

    public func release(_ r: Reservation) {
        held.removeValue(forKey: r)
    }

    private func persist() {
        guard let file, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ProtectedFile.write(data, to: file)
    }
}

/// A rendered clip with measured duration.
public struct CachedAudio: Codable, Equatable, Sendable {
    public let data: Data
    public let seconds: Double
    public let providerID: String
    public let voiceID: String
    /// Personal items this audio was derived from; used to purge it when a source is deleted or revoked.
    public var sourceItemIDs: [UUID]
    public var createdAt: Date

    public init(data: Data, seconds: Double, providerID: String, voiceID: String,
                sourceItemIDs: [UUID] = [], createdAt: Date = Date()) {
        self.data = data
        self.seconds = seconds
        self.providerID = providerID
        self.voiceID = voiceID
        self.sourceItemIDs = sourceItemIDs
        self.createdAt = createdAt
    }

    /// Same audio and provenance; `createdAt` is cache bookkeeping and is not compared.
    public static func == (l: CachedAudio, r: CachedAudio) -> Bool {
        l.data == r.data && l.seconds == r.seconds && l.providerID == r.providerID
            && l.voiceID == r.voiceID && l.sourceItemIDs == r.sourceItemIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(Data.self, forKey: .data)
        seconds = try c.decode(Double.self, forKey: .seconds)
        providerID = try c.decode(String.self, forKey: .providerID)
        voiceID = try c.decode(String.self, forKey: .voiceID)
        sourceItemIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceItemIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast  // unknown age: treat as expired
    }
}

/// Retention for cached narration audio. Final beta default: 7 days, and never longer.
public enum AudioCacheRetention {
    public static let maximum: TimeInterval = 7 * 24 * 3600
    static func clamp(_ age: TimeInterval) -> TimeInterval { min(max(0, age), maximum) }
}

public protocol AudioCache: Sendable {
    func audio(for key: String) async -> CachedAudio?
    func store(_ audio: CachedAudio, for key: String) async
    /// Removes every clip derived from any of these personal items (source deleted or consent revoked).
    func purge(sourceItemIDs: Set<UUID>) async
    /// Removes clips older than the retention limit.
    func purgeExpired() async
}

public actor InMemoryAudioCache: AudioCache {
    private var clips: [String: CachedAudio] = [:]
    public nonisolated let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    public init(maxAge: TimeInterval = AudioCacheRetention.maximum, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxAge = AudioCacheRetention.clamp(maxAge)
        self.now = now
    }
    public func audio(for key: String) -> CachedAudio? {
        guard let clip = clips[key] else { return nil }
        guard now().timeIntervalSince(clip.createdAt) <= maxAge else { clips[key] = nil; return nil }
        return clip
    }
    /// Stamps `createdAt` with the cache's clock, so retention is measured from when it was stored.
    public func store(_ audio: CachedAudio, for key: String) {
        var stamped = audio; stamped.createdAt = now(); clips[key] = stamped
    }
    public func purge(sourceItemIDs: Set<UUID>) {
        clips = clips.filter { sourceItemIDs.isDisjoint(with: $0.value.sourceItemIDs) }
    }
    public func purgeExpired() { clips = clips.filter { now().timeIntervalSince($0.value.createdAt) <= maxAge } }
    public var count: Int { clips.count }
}

/// On-device cache, one protected file per key. Personal narration stays on
/// this device; nothing is shared across users. Entries older than
/// `maxAge` are ignored and removed.
public struct FileAudioCache: AudioCache {
    public let directory: URL
    public let maxAge: TimeInterval

    private let now: @Sendable () -> Date

    /// `maxAge` is clamped to `AudioCacheRetention.maximum` (7 days).
    public init(directory: URL, maxAge: TimeInterval = AudioCacheRetention.maximum,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxAge = AudioCacheRetention.clamp(maxAge)
        self.now = now
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    private func read(_ file: URL) -> CachedAudio? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CachedAudio.self, from: $0) }
    }

    public func audio(for key: String) async -> CachedAudio? {
        let file = url(key)
        guard let clip = read(file) else { return nil }
        guard now().timeIntervalSince(clip.createdAt) <= maxAge else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return clip
    }

    private func entries() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    public func purge(sourceItemIDs: Set<UUID>) async {
        for file in entries() {
            // Unreadable entries cannot be attributed, so they are removed too.
            if let clip = read(file), sourceItemIDs.isDisjoint(with: clip.sourceItemIDs) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func purgeExpired() async {
        for file in entries() {
            if let clip = read(file), now().timeIntervalSince(clip.createdAt) <= maxAge { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func store(_ audio: CachedAudio, for key: String) async {
        var stamped = audio; stamped.createdAt = now()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ProtectedFile.write(data, to: url(key))
    }
}

public struct RenderedClip: Equatable, Sendable {
    public let cueID: UUID
    public let audio: CachedAudio
    public let cacheKey: String
    public let attempts: [VoiceAttempt]
}

/// Result of rendering a handoff: cues that rendered carry measured
/// durations and voice metadata; the rest have an explicit drop reason.
public struct RenderedNarration: Sendable {
    public let original: NarrationHandoff
    /// Only rendered cues, with `renderedSeconds`/`voiceID`/`providerID`/`audioCacheKey` set.
    public let handoff: NarrationHandoff
    public let clips: [UUID: RenderedClip]
    public let failures: [UUID: (reason: NarrationDropReason, attempts: [VoiceAttempt])]

    /// Scheduler report for the rendered handoff, extended so every original
    /// cue keeps exactly one outcome (render failures become `.dropped`).
    public func report(merging scheduled: NarrationScheduleReport) -> NarrationScheduleReport {
        let byID = Dictionary(uniqueKeysWithValues: scheduled.entries.map { ($0.cue.id, $0) })
        return NarrationScheduleReport(entries: original.cues.map { cue in
            if let entry = byID[cue.id] { return entry }
            return NarrationScheduleEntry(cue: cue, outcome: .dropped(failures[cue.id]?.reason ?? .renderFailed))
        }, unexpectedSegmentIDs: scheduled.unexpectedSegmentIDs)
    }
}

/// Renders cues through the route chain: cache -> paid route (if within the
/// user's daily cap and before its timeout) -> next route ... -> on-device.
/// Tombstones for personal items whose narration was purged (consent withdrawn, item revoked,
/// deleted or demoted). A render that started before a purge must not leave audio for that item
/// in the cache: `VoiceRenderer` takes a token before synthesis and re-checks it around the cache
/// write. `NarrationPurger` marks items here *before* purging, so either the purge removes the
/// stored clip, or the renderer sees the mark and removes it itself. Process-wide by default so
/// the app's purger and renderer agree without extra wiring; tests inject their own.
public final class NarrationRevocations: @unchecked Sendable {
    public static let shared = NarrationRevocations()
    private let lock = NSLock()
    private var clock: UInt64 = 0
    private var revokedAt: [UUID: UInt64] = [:]

    public init() {}

    /// The current revocation clock. Anything revoked after this token is `revoked(since:)`.
    public func token() -> UInt64 { lock.withLock { clock } }

    /// Marks items as revoked now.
    public func revoke(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            clock &+= 1
            for id in ids { revokedAt[id] = clock }
        }
    }

    /// Whether any of `ids` was revoked after `token` was taken.
    public func revoked(_ ids: [UUID], since token: UInt64) -> Bool {
        guard !ids.isEmpty else { return false }
        return lock.withLock { ids.contains { (revokedAt[$0] ?? 0) > token } }
    }
}

public struct VoiceRenderer: Sendable {
    public static let cacheFormatVersion = "v1"
    public let routes: [VoiceRoute]
    public let budget: VoiceBudget
    public let cache: any AudioCache
    public let revocations: NarrationRevocations

    public init(routes: [VoiceRoute], budget: VoiceBudget, cache: any AudioCache,
                revocations: NarrationRevocations = .shared) {
        self.routes = routes
        self.budget = budget
        self.cache = cache
        self.revocations = revocations
    }

    public static func cacheKey(text: String, route: VoiceRoute) -> String {
        SHA256Digest.hex([cacheFormatVersion, route.providerID, route.voice.id, route.acceptsSSML ? "ssml" : "text", text]
            .joined(separator: "\u{1F}"))
    }

    public func render(_ handoff: NarrationHandoff, userID: String, stationID: String) async -> RenderedNarration {
        var cues: [NarrationCue] = []
        var clips: [UUID: RenderedClip] = [:]
        var failures: [UUID: (NarrationDropReason, [VoiceAttempt])] = [:]
        for cue in handoff.cues {
            switch await render(cue, userID: userID, stationID: stationID) {
            case .success(let clip):
                var rendered = cue
                rendered.renderedSeconds = clip.audio.seconds
                rendered.voiceID = clip.audio.voiceID
                rendered.providerID = clip.audio.providerID
                rendered.audioCacheKey = clip.cacheKey
                cues.append(rendered)
                clips[cue.id] = clip
            case .failure(let failure):
                failures[cue.id] = (failure.reason, failure.attempts)
            }
        }
        return RenderedNarration(original: handoff,
                                 handoff: NarrationHandoff(cues: cues, maxSpokenSeconds: handoff.maxSpokenSeconds,
                                                           experienceSeconds: handoff.experienceSeconds),
                                 clips: clips, failures: failures.mapValues { (reason: $0.0, attempts: $0.1) })
    }

    public struct Failure: Error, Sendable {
        public let reason: NarrationDropReason
        public let attempts: [VoiceAttempt]
    }

    public func render(_ cue: NarrationCue, userID: String, stationID: String) async -> Result<RenderedClip, Failure> {
        var attempts: [VoiceAttempt] = []
        let sources = cue.sourceItemID.map { [$0] } ?? []
        let token = revocations.token()  // before any synthesis: a later purge of `sources` wins
        for route in routes {
            if Task.isCancelled { return .failure(Failure(reason: .renderFailed, attempts: attempts + [VoiceAttempt(providerID: route.providerID, result: .cancelled)])) }
            let text = route.acceptsSSML ? SpeechDelivery.ssml(cue.text) : SpeechDelivery.speakable(cue.text)
            let key = Self.cacheKey(text: text, route: route)
            if let cached = await cache.audio(for: key), cached.seconds <= Double(cue.maxSeconds) {
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .cacheHit))
                return .success(RenderedClip(cueID: cue.id, audio: cached, cacheKey: key, attempts: attempts))
            }
            var reservation: VoiceBudget.Reservation?
            if route.isPaid {
                guard let r = await budget.reserve(userID: userID, microdollars: route.cost(characters: text.count)) else {
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .overCostCap))
                    continue
                }
                reservation = r
            }
            let context = RequestContext(stationID: stationID, isReusableGeneric: false)
            do {
                let artifact = try await Self.withTimeout(route.timeout) {
                    try await route.provider.synthesize(text, voice: route.voice, context: context)
                }
                if let r = reservation { await budget.commit(r, microdollars: route.cost(characters: artifact.billableUnits)) }
                guard !artifact.data.isEmpty, artifact.durationSeconds.isFinite, artifact.durationSeconds > 0 else {
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .invalidAudio))
                    continue
                }
                guard artifact.durationSeconds <= Double(cue.maxSeconds) else {
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .overDuration(artifact.durationSeconds)))
                    continue
                }
                let audio = CachedAudio(data: artifact.data, seconds: artifact.durationSeconds,
                                        providerID: route.providerID, voiceID: route.voice.id,
                                        sourceItemIDs: cue.sourceItemID.map { [$0] } ?? [])
                if Task.isCancelled || revocations.revoked(sources, since: token) {
                    // The caller gave up, or the source was purged mid-render: nothing is cached or returned.
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                    return .failure(Failure(reason: .renderFailed, attempts: attempts))
                }
                await cache.store(audio, for: key)
                if revocations.revoked(sources, since: token) {
                    // A purge landed while the write was in flight and may have run before it:
                    // remove what we just wrote. (A purge after the write removes it itself.)
                    await cache.purge(sourceItemIDs: Set(sources))
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                    return .failure(Failure(reason: .renderFailed, attempts: attempts))
                }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .rendered))
                return .success(RenderedClip(cueID: cue.id, audio: audio, cacheKey: key, attempts: attempts))
            } catch is CancellationError {
                // Cancelled by the caller (skip, stop, consent revoked): release the hold and stop trying routes.
                if let r = reservation { await budget.release(r) }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                return .failure(Failure(reason: .renderFailed, attempts: attempts))
            } catch VoiceRenderError.timedOut {
                // The provider may still bill a request we stopped waiting for.
                if let r = reservation { await budget.commit(r, microdollars: r.microdollars) }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .timedOut))
            } catch {
                if let r = reservation { await budget.release(r) }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(String(describing: error))))
            }
        }
        let overDuration = attempts.contains { if case .overDuration = $0.result { true } else { false } }
        return .failure(Failure(reason: overDuration ? .overDuration : .renderFailed, attempts: attempts))
    }

    /// Returns at the deadline even if the provider ignores cancellation
    /// (a task group would wait for it).
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce<T>()
        let worker = Task {
            do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { worker.cancel(); once.resume(.failure(VoiceRenderError.timedOut)) }
        }
        once.onResume { timer.cancel() }
        // Caller cancellation returns at once, even if the provider ignores cancellation.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { once.set($0) }
        } onCancel: {
            worker.cancel()
            once.resume(.failure(CancellationError()))
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var cleanup: (@Sendable () -> Void)?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock(); continuation = c; let early = pending; pending = nil; lock.unlock()
        if let early { c.resume(with: early) }
    }

    func onResume(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let finished = done; if !finished { cleanup = action }; lock.unlock()
        if finished { action() }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = continuation; continuation = nil
        if c == nil { pending = result }
        let action = cleanup; cleanup = nil
        lock.unlock()
        c?.resume(with: result)
        action?()
    }
}

/// Future Dessa voice. **Not implemented**: there is no Dessa API contract
/// yet, so this always throws and must not be placed ahead of a working route.
public struct DessaVoiceProvider: VoiceProvider {
    public static let providerID = "dessa"
    public init() {}
    public func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        throw VoiceRenderError.notImplemented("Dessa adapter is not implemented yet")
    }
}
