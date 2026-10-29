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

    /// True for any route that sends text off the device (a cloud or proxy voice), even one
    /// priced at 0 like the owner A/B ElevenLabs route. Such a route never speaks private text.
    public let leavesDevice: Bool

    public var isPaid: Bool { microdollarsPerThousandCharacters > 0 }
    /// On-device and free: safe for private text and for the over-cap fallback.
    public var isLocalAndFree: Bool { !leavesDevice && !isPaid }

    public init(providerID: String, provider: any VoiceProvider, voice: VoiceProfile,
                microdollarsPerThousandCharacters: Int = 0, timeout: Duration = .seconds(8), acceptsSSML: Bool = false,
                leavesDevice: Bool = false) {
        self.leavesDevice = leavesDevice
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

/// Owner-approved beta voice defaults. Paid (cloud) voice spend is $0: any paid route is refused
/// by the budget and the renderer falls back to on-device speech. Changing this needs a new
/// owner approval.
public enum VoiceBetaDefaults {
    public static let paidDailyCapMicrodollars = 0
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
    /// Removes every clip derived from any personal item, whatever its id. For when consent
    /// cannot be checked per item (live mode does not persist consent across launches).
    func purgeAllPersonal() async
}

/// Enforces the 7-day cap on a schedule, not only when a clip is read: an expired clip that
/// is never asked for again is still deleted. `run` sweeps once at start and once per tick.
public struct AudioCacheSweeper: Sendable {
    public static let defaultInterval: Duration = .seconds(3600)
    public let cache: any AudioCache

    public init(cache: any AudioCache) { self.cache = cache }

    /// Production entry point. With `purgingPersonalFirst`, personal clips left by an earlier
    /// launch are removed before the first sweep (live consent is not persisted).
    @discardableResult
    public func start(every interval: Duration = Self.defaultInterval, purgingPersonalFirst: Bool,
                      onLaunchSweep: @escaping @Sendable (String?) -> Void = { _ in }) -> Task<Void, Never> {
        let cache = cache
        let ticks = Self.ticks(every: interval)
        return Task.detached(priority: .utility) {
            let line = await AudioCacheSweeper(cache: cache).prepareForLaunch(purgingPersonalFirst: purgingPersonalFirst)
            onLaunchSweep(line)
            for await _ in ticks {
                if Task.isCancelled { return }
                await cache.purgeExpired()
            }
        }
    }

    /// The launch step, finished before the first tick: personal clips from an earlier launch
    /// (when asked), expired clips and unattributable files are deleted, then the count of what
    /// is left is logged. Returns the log line (nil if the cache can't count).
    @discardableResult
    public func prepareForLaunch(purgingPersonalFirst: Bool) async -> String? {
        if purgingPersonalFirst { await cache.purgeAllPersonal() }
        await cache.purgeExpired()
        return await AudioCacheFileLog.record(cache, after: .launch)
    }

    /// Sweeps now, then after each tick, until `ticks` finishes or the task is cancelled.
    /// `onSweep` runs after each sweep completes (tests wait on it instead of sleeping).
    public func run(ticks: AsyncStream<Void>, onSweep: @Sendable () -> Void = {}) async {
        await cache.purgeExpired()
        onSweep()
        for await _ in ticks {
            if Task.isCancelled { return }
            await cache.purgeExpired()
            onSweep()
        }
    }

    static func ticks(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in timer.cancel() }
        }
    }
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
    /// A clip stamped later than now (stored while the clock ran ahead) is first re-stamped to
    /// now, so its 7 days run from no later than the first sweep after the clock is corrected.
    public func purgeExpired() {
        let t = now()
        for (key, clip) in clips where clip.createdAt > t { clips[key]?.createdAt = t }
        clips = clips.filter { t.timeIntervalSince($0.value.createdAt) <= maxAge }
    }
    public func purgeAllPersonal() { clips = clips.filter { $0.value.sourceItemIDs.isEmpty } }
    public var count: Int { clips.count }
}

extension InMemoryAudioCache: AudioCacheCounting {
    public func fileCount() -> AudioCacheCount {
        AudioCacheCount(files: clips.count, personal: clips.values.filter { !$0.sourceItemIDs.isEmpty }.count)
    }
}

extension FileAudioCache: AudioCacheCounting {
    /// Every file counts, metadata and audio alike. Files of personal or unattributable keys
    /// (orphaned audio included) count as personal.
    public func fileCount() async -> AudioCacheCount {
        let groups = groups()
        return AudioCacheCount(files: groups.reduce(0) { $0 + $1.files.count },
                               personal: groups.filter { $0.clip.map { !$0.sourceItemIDs.isEmpty } ?? true }
                                   .reduce(0) { $0 + $1.files.count })
    }
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
        guard let clip = read(url(key)).map({ clampingFutureStamp($0, key: key) }) else { return nil }
        guard now().timeIntervalSince(clip.createdAt) <= maxAge else {
            remove(group: key)
            return nil
        }
        return clip
    }

    /// Every regular file in the cache directory, any extension: `.json` metadata and any
    /// audio beside it (`<key>.caf`, `<key>.m4a`, ...), so orphaned audio is seen too.
    private func allFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
    }

    /// Files grouped by key (file name without extension), with the key's clip if its
    /// metadata is readable. A group with no readable metadata (orphaned audio, corrupt
    /// file) cannot be attributed, so every purge removes it.
    private func groups() -> [(key: String, files: [URL], clip: CachedAudio?)] {
        Dictionary(grouping: allFiles(), by: { $0.deletingPathExtension().lastPathComponent })
            .map { key, files in (key, files, files.contains { $0.pathExtension == "json" } ? read(url(key)) : nil) }
    }

    /// Clock skew: a clip stamped later than now (stored while the clock ran ahead) is re-stamped
    /// to now and saved, so its 7 days run from no later than the first sweep or read after the
    /// clock is corrected, and it cannot outlive the cap by the size of the skew.
    private func clampingFutureStamp(_ clip: CachedAudio, key: String) -> CachedAudio {
        let t = now()
        guard clip.createdAt > t else { return clip }
        var clamped = clip
        clamped.createdAt = t
        if let data = try? JSONEncoder().encode(clamped) { try? ProtectedFile.write(data, to: url(key)) }
        return clamped
    }

    /// Deletes a key's metadata together with its audio, whatever the audio's extension.
    private func remove(group key: String) {
        for file in allFiles() where file.deletingPathExtension().lastPathComponent == key {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func removeGroups(where shouldRemove: (CachedAudio?) -> Bool) {
        for group in groups() where shouldRemove(group.clip) {
            for file in group.files { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func purge(sourceItemIDs: Set<UUID>) async {
        removeGroups { clip in clip.map { !sourceItemIDs.isDisjoint(with: $0.sourceItemIDs) } ?? true }
    }

    public func purgeExpired() async {
        let t = now()
        for group in groups() {
            let clip = group.clip.map { clampingFutureStamp($0, key: group.key) }
            guard clip.map({ t.timeIntervalSince($0.createdAt) > maxAge }) ?? true else { continue }
            for file in group.files { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func purgeAllPersonal() async {
        removeGroups { clip in clip.map { !$0.sourceItemIDs.isEmpty } ?? true }
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
    /// Most tombstones kept. Older ones are dropped, and any render whose token is older than
    /// a dropped tombstone is treated as revoked (fails closed; music continues).
    public let limit: Int
    private let lock = NSLock()
    private var clock: UInt64 = 0
    private var revokedAt: [UUID: UInt64] = [:]
    /// Highest clock among dropped tombstones.
    private var evictedThrough: UInt64 = 0
    /// Clock of the last "purge all personal narration".
    private var allRevokedAt: UInt64 = 0
    /// Purges started and not yet finished: renders for these items are refused meanwhile.
    private var pending: [UUID: Int] = [:]
    private var pendingAll = 0

    public init(limit: Int = 4096) { self.limit = max(1, limit) }

    /// The current revocation clock. Anything revoked after this token is `revoked(since:)`.
    public func token() -> UInt64 { lock.withLock { clock } }

    /// Marks items as revoked now, with their purge pending until `purgeCompleted`.
    public func revoke(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            clock &+= 1
            for id in ids { revokedAt[id] = clock; pending[id, default: 0] += 1 }
            evictIfNeeded()
        }
    }

    /// The purge started by `revoke(ids)` finished.
    public func purgeCompleted(_ ids: Set<UUID>) {
        lock.withLock {
            for id in ids {
                let left = (pending[id] ?? 1) - 1
                pending[id] = left > 0 ? left : nil
            }
        }
    }

    /// Every personal item counts as revoked now (ids unknown), pending until `purgeAllCompleted`.
    public func revokeAll() {
        lock.withLock { clock &+= 1; allRevokedAt = clock; pendingAll += 1 }
    }

    public func purgeAllCompleted() { lock.withLock { pendingAll = max(0, pendingAll - 1) } }

    /// Whether any of `ids` was revoked after `token` was taken.
    public func revoked(_ ids: [UUID], since token: UInt64) -> Bool {
        guard !ids.isEmpty else { return false }
        return lock.withLock {
            allRevokedAt > token || evictedThrough > token || ids.contains { (revokedAt[$0] ?? 0) > token }
        }
    }

    /// Whether a purge covering any of `ids` is still running.
    public func purgePending(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return false }
        return lock.withLock { pendingAll > 0 || ids.contains { pending[$0] != nil } }
    }

    /// Tombstones held now (at most `limit`).
    public var count: Int { lock.withLock { revokedAt.count } }

    private func evictIfNeeded() {
        guard revokedAt.count > limit else { return }
        // Drop the oldest quarter at once, so eviction is not paid on every revoke.
        let keep = max(1, limit - limit / 4)
        let oldest = revokedAt.sorted { $0.value < $1.value }.prefix(revokedAt.count - keep)
        for (id, at) in oldest { revokedAt[id] = nil; evictedThrough = max(evictedThrough, at) }
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

    /// The last route alone (the on-device standard voice), sharing this renderer's budget,
    /// cache and revocations. Nil when there is only one route, or when the last route is paid
    /// or leaves the device (Sentinel, #154). `DJBreakPreparer` uses it to re-render a break
    /// that ran over its cap; it is a narrowed view, not a second renderer.
    public var lastRouteOnly: VoiceRenderer? {
        guard routes.count > 1, let last = routes.last, last.isLocalAndFree else { return nil }
        return VoiceRenderer(routes: [last], budget: budget, cache: cache, revocations: revocations)
    }

    /// Only the on-device, free routes, in order, sharing this renderer's budget, cache and
    /// revocations. Nil when there are none. Used for breaks on a station with a library seed:
    /// the listener's own library never goes to a cloud or paid voice. A narrowed view, not a
    /// second renderer.
    public var onDeviceOnly: VoiceRenderer? {
        let local = routes.filter(\.isLocalAndFree)
        guard !local.isEmpty else { return nil }
        return VoiceRenderer(routes: local, budget: budget, cache: cache, revocations: revocations)
    }

    /// Attempt detail for an off-device route skipped for a local-only cue. Fixed text, no cue text.
    public static let localOnlySkip = "local-only cue: off-device route skipped"

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

    /// Whether `cue` may be sent to a route that leaves the device (#176). Fail-closed: only a
    /// cue with an explicit non-personal attribution (`.presenter` or `.trackMetadata`) that is
    /// itself a DJ transition with no source item, source kind or provenance is eligible.
    /// Missing attribution, `.personalContext`, any sourced or briefing cue (Calendar, Share,
    /// Obsidian, library notes…) or a cue whose fields disagree with its attribution is local-only.
    public static func mayLeaveDevice(_ cue: NarrationCue, attribution: SpokenAttribution?) -> Bool {
        guard let attribution else { return false }
        switch attribution {
        case .personalContext: return false
        case .presenter, .trackMetadata: break
        }
        return cue.kind == .transition && !cue.isContent && cue.source == nil && cue.provenance == nil
    }

    /// Renders `cue` on the first route that succeeds. Routes that leave the device are skipped
    /// (never looked up in the cache, reserved against or called) unless
    /// `mayLeaveDevice(cue, attribution:)` holds. With no attribution the cue is local-only, and
    /// if no local route exists it fails closed with `.renderFailed`; it never falls back to cloud.
    public func render(_ cue: NarrationCue, userID: String, stationID: String,
                       attribution: SpokenAttribution? = nil) async -> Result<RenderedClip, Failure> {
        var attempts: [VoiceAttempt] = []
        let sources = cue.sourceItemID.map { [$0] } ?? []
        let token = revocations.token()  // before any synthesis: a later purge of `sources` wins
        if revocations.purgePending(sources) {
            // A purge of this item is still running: render nothing that it could miss.
            return .failure(Failure(reason: .renderFailed, attempts: [VoiceAttempt(providerID: routes.first?.providerID ?? "", result: .cancelled)]))
        }
        // Decided once, before any cache key, reservation or provider call (#176).
        let offDeviceAllowed = Self.mayLeaveDevice(cue, attribution: attribution)
        for route in routes {
            if route.leavesDevice && !offDeviceAllowed {
                // Local-only cue: its text never reaches this route, its cache keys or its budget.
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.localOnlySkip)))
                continue
            }
            if Task.isCancelled { return .failure(Failure(reason: .renderFailed, attempts: attempts + [VoiceAttempt(providerID: route.providerID, result: .cancelled)])) }
            let text = route.acceptsSSML ? SpeechDelivery.ssml(cue.text) : SpeechDelivery.speakable(cue.text)
            let key = Self.cacheKey(text: text, route: route)
            if let cached = await cache.audio(for: key), cached.seconds <= Double(cue.maxSeconds) {
                // Keys are text + voice, so the clip may carry other items' ids: check both.
                let hitSources = Array(Set(sources).union(cached.sourceItemIDs))
                if revocations.revoked(hitSources, since: token) || revocations.purgePending(hitSources) {
                    // Revoked while the read was in flight: never hand back, and remove, that clip.
                    await cache.purge(sourceItemIDs: Set(hitSources))
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                    return .failure(Failure(reason: .renderFailed, attempts: attempts))
                }
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
            if !Task.isCancelled { once.resume(.failure(VoiceRenderError.timedOut)); worker.cancel() }
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
