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
    /// The paid proxy route is backing off after a 429 or 5xx (`PaidVoiceBackoff`); no call was made.
    case suspended
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

    /// The route forwards the neighbouring lines of the same break as stitching context
    /// (ElevenLabs `previous_text` / `next_text`, through the proxy). Off unless the route leaves
    /// the device: an on-device route cannot be given this, and a cue still sends context only
    /// when `mayLeaveDevice` already allows that cue off the device.
    public let sendsSpeechContext: Bool

    /// The voice reads square-bracket audio tags (ElevenLabs v3/v4), so an allowlisted tag such
    /// as `[warmly]` is kept for it. Off by default on every route. With it off, every `[` and `]`
    /// is stripped before off-device text leaves the device.
    public let supportsAudioTags: Bool

    public var isPaid: Bool { microdollarsPerThousandCharacters > 0 }
    /// On-device and free: safe for private text and for the over-cap fallback.
    public var isLocalAndFree: Bool { !leavesDevice && !isPaid }

    public init(providerID: String, provider: any VoiceProvider, voice: VoiceProfile,
                microdollarsPerThousandCharacters: Int = 0, timeout: Duration = .seconds(8), acceptsSSML: Bool = false,
                leavesDevice: Bool = false, sendsSpeechContext: Bool = false, supportsAudioTags: Bool = false) {
        self.leavesDevice = leavesDevice
        // On-device routes never carry stitching context, whatever the caller asked.
        self.sendsSpeechContext = sendsSpeechContext && leavesDevice
        self.supportsAudioTags = supportsAudioTags
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
    /// The launch purge (owner, Nov 9 2026): every clip derived from a personal item, like
    /// `purgeAllPersonal`, but a clip tagged only `VoiceRenderer.allLinesClipTag` (a library song
    /// or a typed station name in the cloud voice, no item id) is kept between launches, so it is
    /// not paid for again. "Delete my DJ data" (`purgeAllPersonal`) still removes it.
    func purgePersonalItems() async
    /// Removes every clip not rendered by one of `providerIDs` (cloud-voice consent withdrawn,
    /// Echo's N2 on #395: cloud and paid clips go, on-device clips stay). Unattributable entries
    /// are removed too. Same shape as #258's, so the two converge when it lands. -Nova
    func purgeClips(keepingProviders providerIDs: Set<String>) async
}

extension AudioCache {
    /// Test doubles that never hold cloud audio. Both shipping caches implement this.
    public func purgeClips(keepingProviders providerIDs: Set<String>) async {}
    /// Fail-safe default for test doubles: everything personal goes. Both shipping caches and
    /// `CloudVoiceConsentCache` implement it.
    public func purgePersonalItems() async { await purgeAllPersonal() }
}

extension CachedAudio {
    /// Derived from a real personal item: any source id other than `VoiceRenderer.allLinesClipTag`.
    var hasPersonalItem: Bool { sourceItemIDs.contains { $0 != VoiceRenderer.allLinesClipTag } }
}

/// Enforces the 7-day cap on a schedule, not only when a clip is read: an expired clip that
/// is never asked for again is still deleted. `run` sweeps once at start and once per tick.
public struct AudioCacheSweeper: Sendable {
    public static let defaultInterval: Duration = .seconds(3600)
    public let cache: any AudioCache

    public init(cache: any AudioCache) { self.cache = cache }

    /// Production entry point. Personal clips left by an earlier launch are removed before the
    /// first sweep (live consent is not persisted), then the 7-day cap is swept every `interval`.
    ///
    /// #637 follow-up (-Sentinel, Nova's nit): only a `LaunchPurgeGated` cache compiles here, so
    /// reads are gated before the purge task exists in every build, Release included (this was a
    /// Debug-only `assert`). Gate an `any AudioCache` with `LaunchPurgeGatedCache(base:)` and read
    /// through that wrapper. The cache reopens when its `purgePersonalItems` completes.
    @discardableResult
    public static func startPurgingPersonalFirst(_ cache: some LaunchPurgeGated,
                                                 every interval: Duration = Self.defaultInterval,
                                                 onLaunchSweep: @escaping @Sendable (String?) -> Void = { _ in }) -> Task<Void, Never> {
        cache.beginLaunchPurge()
        return AudioCacheSweeper(cache: cache).launch(every: interval, purgingPersonalFirst: true, onLaunchSweep: onLaunchSweep)
    }

    /// Sweeps with no launch purge: expired and unattributable clips at launch, then every
    /// `interval`. Personal clips from an earlier launch stay (use `startPurgingPersonalFirst`).
    @discardableResult
    public func start(every interval: Duration = Self.defaultInterval,
                      onLaunchSweep: @escaping @Sendable (String?) -> Void = { _ in }) -> Task<Void, Never> {
        launch(every: interval, purgingPersonalFirst: false, onLaunchSweep: onLaunchSweep)
    }

    private func launch(every interval: Duration, purgingPersonalFirst: Bool,
                        onLaunchSweep: @escaping @Sendable (String?) -> Void) -> Task<Void, Never> {
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
    /// is left is logged. Returns the log line (nil if the cache can't count). Cloud clips of
    /// library songs and typed station names (`allLinesClipTag` only) are kept (owner, Nov 9
    /// 2026); "Delete my DJ data" removes them.
    @discardableResult
    public func prepareForLaunch(purgingPersonalFirst: Bool) async -> String? {
        if purgingPersonalFirst { await cache.purgePersonalItems() }
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
    /// `async`, matching the protocol requirement exactly (see `purgeClips`).
    public func purgePersonalItems() async { clips = clips.filter { !$0.value.hasPersonalItem } }
    /// `async`, matching the protocol requirement exactly: a synchronous overload here let a
    /// direct `await` call from outside resolve to the no-op `AudioCache` extension default.
    public func purgeClips(keepingProviders providerIDs: Set<String>) async {
        clips = clips.filter { providerIDs.contains($0.value.providerID) }
    }
    public var count: Int { clips.count }
}

extension InMemoryAudioCache: AudioCacheCounting {
    public func fileCount() -> AudioCacheCount {
        AudioCacheCount(files: clips.count, personal: clips.values.filter { !$0.sourceItemIDs.isEmpty }.count)
    }
}

extension FileAudioCache: AudioCacheCounting {
    /// Every file counts, metadata and audio alike. Files of personal or unattributable keys
    /// (orphaned audio included) count as personal. Clips held in memory while the disk is
    /// closed count too (one each), so the launch log never reports an empty cache that isn't.
    public func fileCount() async -> AudioCacheCount {
        let groups = groups()
        let held = await memoryFallback.fileCount()
        return AudioCacheCount(files: groups.reduce(0) { $0 + $1.files.count } + held.files,
                               personal: groups.filter { $0.clip.map { !$0.sourceItemIDs.isEmpty } ?? true }
                                   .reduce(0) { $0 + $1.files.count } + held.personal)
    }
}

/// #637 P1: the file operations whose failures `FileAudioCache` must handle (fail closed).
struct CacheFileOps: Sendable {
    var write: @Sendable (Data, URL) throws -> Void
    var remove: @Sendable (URL) throws -> Void
    static let live = CacheFileOps(write: { try ProtectedFile.write($0, to: $1) },
                                   remove: { try FileManager.default.removeItem(at: $0) })
}

/// On-device cache, one protected file per key. Personal narration stays on
/// this device; nothing is shared across users. Entries older than
/// `maxAge` are ignored and removed.
public struct FileAudioCache: AudioCache {
    public let directory: URL
    public let maxAge: TimeInterval

    private let now: @Sendable () -> Date
    /// Sets the folder's excluded-from-backup flag (src: CacheBackupExclusion.swift).
    let backupExclusion: any BackupExclusionMarking
    /// Sink for the content-free line logged when setting that flag fails.
    let backupExclusionLog: @Sendable (String) -> Void
    /// Closed when the folder cannot be marked excluded: nothing more is written to disk this session.
    let diskGate = CacheDiskGate()
    /// Serves clips stored while the disk is closed, so playback is unaffected (session only).
    let memoryFallback: InMemoryAudioCache
    /// #82 F3: withholds earlier-launch personal clips until the launch purge completes.
    let launchGate = CacheLaunchPurgeGate()
    /// #637 P1: the launch purge's deletions and `store`'s write, injectable so tests can fail them.
    let fileOps: CacheFileOps

    /// `maxAge` is clamped to `AudioCacheRetention.maximum` (7 days).
    /// Opening a cache whose folder already exists re-applies the excluded-from-backup flag,
    /// since a restore can drop it; `store` applies it whenever it (re)creates the folder.
    /// Fail closed: if the flag cannot be set (or reads back unset) on open, every personal clip
    /// in the folder is deleted, and on any failure nothing more is written to disk this session.
    /// By design, generic clips (no `sourceItemIDs`: station idents, generic links) stay on disk
    /// after an open failure: they carry no personal data and are swept by retention as usual.
    public init(directory: URL, maxAge: TimeInterval = AudioCacheRetention.maximum,
                now: @escaping @Sendable () -> Date = { Date() },
                backupExclusion: any BackupExclusionMarking = FoundationBackupExclusion(),
                backupExclusionLog: @escaping @Sendable (String) -> Void = CacheBackupExclusionLog.emit) {
        self.init(directory: directory, maxAge: maxAge, now: now, backupExclusion: backupExclusion,
                  backupExclusionLog: backupExclusionLog, fileOps: .live)
    }

    init(directory: URL, maxAge: TimeInterval = AudioCacheRetention.maximum,
         now: @escaping @Sendable () -> Date = { Date() },
         backupExclusion: any BackupExclusionMarking = FoundationBackupExclusion(),
         backupExclusionLog: @escaping @Sendable (String) -> Void = CacheBackupExclusionLog.emit,
         fileOps: CacheFileOps) {
        self.fileOps = fileOps
        self.directory = directory
        self.maxAge = AudioCacheRetention.clamp(maxAge)
        self.now = now
        self.backupExclusion = backupExclusion
        self.backupExclusionLog = backupExclusionLog
        self.memoryFallback = InMemoryAudioCache(maxAge: maxAge, now: now)
        if FileManager.default.fileExists(atPath: directory.path), !applyBackupExclusion(.open) {
            diskGate.close()
            removePersonalGroups()
        }
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    private func read(_ file: URL) -> CachedAudio? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CachedAudio.self, from: $0) }
    }

    public func audio(for key: String) async -> CachedAudio? {
        if let held = await memoryFallback.audio(for: key) { return held }
        // #82 F3: decided before the read, so a clip from an earlier launch is never served
        // while the launch purge may still delete it. Not deleted here; the purge does that.
        let withholdPersonal = launchGate.withholdsPersonal(key)
        guard let raw = read(url(key)), !(withholdPersonal && raw.hasPersonalItem) else { return nil }
        let clip = clampingFutureStamp(raw, key: key)
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
        if !diskGate.isClosed, let data = try? JSONEncoder().encode(clamped) { try? ProtectedFile.write(data, to: url(key)) }
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
        await memoryFallback.purge(sourceItemIDs: sourceItemIDs)
        removeGroups { clip in clip.map { !sourceItemIDs.isDisjoint(with: $0.sourceItemIDs) } ?? true }
    }

    public func purgeExpired() async {
        // #637 P1: a launch purge that left a file behind is retried on every sweep until it
        // removes everything; the gate keeps withholding until then.
        if launchGate.needsRetry { await purgePersonalItems() }
        await memoryFallback.purgeExpired()
        let t = now()
        for group in groups() {
            let clip = group.clip.map { clampingFutureStamp($0, key: group.key) }
            guard clip.map({ t.timeIntervalSince($0.createdAt) > maxAge }) ?? true else { continue }
            for file in group.files { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func purgeAllPersonal() async {
        await memoryFallback.purgeAllPersonal()
        removePersonalGroups()
    }

    /// The launch purge: personal-item and unattributable files go; `allLinesClipTag`-only clips stay.
    /// #82 F3: during a gated launch, clips stored in this launch (on disk or held in memory) are
    /// kept, since they are not from an earlier launch. Each deletion is checked under the disk
    /// lock that orders it against a store, and the read gate opens when this completes.
    /// #637 P1 (fail closed): the gate opens only if every deletion succeeded. Otherwise it stays
    /// pending (or starts withholding), so the surviving clip is never served, and the next
    /// `purgeExpired` sweep runs this again.
    public func purgePersonalItems() async {
        // Memory holds only this session's clips; during a gated launch they are all this launch's.
        if !launchGate.isPending { await memoryFallback.purgePersonalItems() }
        var allRemoved = true
        for group in groups() where group.clip.map(\.hasPersonalItem) ?? true {
            diskGate.serialized { _ in
                guard !launchGate.storedThisLaunch(group.key) else { return }
                for file in group.files {
                    // Already gone (a concurrent purge) counts as removed.
                    do { try fileOps.remove(file) } catch {
                        if FileManager.default.fileExists(atPath: file.path) { allRemoved = false }
                    }
                }
            }
        }
        if allRemoved { launchGate.finish() } else { launchGate.purgeFailed() }
    }

    /// Personal and unattributable files (the same rule as `purgeAllPersonal`), synchronously.
    private func removePersonalGroups() {
        removeGroups { clip in clip.map { !$0.sourceItemIDs.isEmpty } ?? true }
    }

    public func purgeClips(keepingProviders providerIDs: Set<String>) async {
        // Clips held in memory while the disk is closed obey the cloud-consent purge too.
        await memoryFallback.purgeClips(keepingProviders: providerIDs)
        removeGroups { clip in clip.map { !providerIDs.contains($0.providerID) } ?? true }
    }

    /// Fail closed: if the folder could not be marked excluded from backup (on open, or now when
    /// creating it), the clip is held in memory for this session and nothing is written to disk.
    public func store(_ audio: CachedAudio, for key: String) async {
        var stamped = audio; stamped.createdAt = now()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        // Create + mark + write under the gate's lock: a concurrent store can neither see a
        // folder that was created but not yet marked, nor write after a failed mark closed it.
        let written = diskGate.serialized { closed -> Bool in
            guard !closed else { return false }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Created or re-created (after a delete): the new folder has no flag yet.
                guard applyBackupExclusion(.create) else {
                    closed = true
                    // Leave no unmarked folder behind (only if empty: never delete foreign files).
                    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    return false
                }
            }
            // #637 P1 (fail closed): only a write that succeeded marks the key fresh. On failure
            // nothing is recorded or held in memory, and whatever is at the key (a partial file,
            // or older bytes) is removed; if that fails too it stays withheld while gated.
            do {
                try fileOps.write(data, url(key))
            } catch {
                launchGate.unmarkStored(key)
                try? fileOps.remove(url(key))
                return true                               // handled: a miss, never old bytes
            }
            launchGate.markStored(key)                    // #82 F3: under the same lock as the purge
            return true
        }
        if !written { await memoryFallback.store(audio, for: key) }
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

/// Where a track entered the queue (Sentinel). Set by the app where tracks are built from
/// MusicKit: catalog search and catalog seed lookups are `.catalog`, `MusicLibraryRequest`
/// results are `.library`, anything else is `.unknown`. Fail-closed: only `.catalog` is
/// non-personal; `.library` and `.unknown` narration never leaves the device.
public enum TrackOrigin: String, Codable, Equatable, Hashable, Sendable {
    case catalog, library, unknown

    /// The more restrictive of two origins: `.library` over `.unknown` over `.catalog`.
    public func restricted(by other: TrackOrigin) -> TrackOrigin {
        if self == .library || other == .library { return .library }
        if self == .unknown || other == .unknown { return .unknown }
        return .catalog
    }
}

extension SpokenAttribution {
    /// Track metadata with `origin` derived from `tracks` (any existing origin is replaced): the
    /// most restrictive origin of every named id, `.unknown` when an id is not in `tracks` or
    /// no id is named. Other attributions are returned unchanged.
    public func resolvingTrackOrigins(in tracks: [DJTrack]) -> SpokenAttribution {
        guard case .trackMetadata(let ids, _) = self else { return self }
        var origin: TrackOrigin = ids.isEmpty ? .unknown : .catalog
        for id in ids {
            let matches = tracks.filter { $0.id == id }
            origin = origin.restricted(by: matches.isEmpty ? .unknown
                                       : matches.map(\.origin).reduce(.catalog) { $0.restricted(by: $1) })
        }
        return .trackMetadata(trackIDs: ids, origin: origin)
    }
}

/// Which DJ lines a route that leaves the device or is paid may hear (`VoiceRenderer.mayLeaveDevice`).
/// Owner, Nov 9 2026: "I want it all elevenlabs." The wider scope needs cloud-voice consent to
/// the copy that says so (`CloudVoiceConsentCopy.version` 3 since #432, `CloudVoiceConsentStore.scope`). -Fry
public enum CloudVoiceScope: Equatable, Sendable {
    /// Nothing leaves the device: no consent to the current copy, or the cloud voice is off.
    case noLines
    /// #176: only an attributed, non-personal DJ transition with no source or provenance. The
    /// default for a renderer with no consent check (owner A/B build, on-device default, tests).
    case transitionsOnly
    /// Copy v3 accepted (#432; v2 before OnAirly 2.0): every attributed line, including personal items (calendar, shared
    /// email digest, notes), news and weather, library tracks and typed station names. A cue
    /// with no attribution still stays on the device.
    case allLines
}

public struct VoiceRenderer: Sendable {
    public static let cacheFormatVersion = "v1"
    public let routes: [VoiceRoute]
    public let budget: VoiceBudget
    public let cache: any AudioCache
    public let revocations: NarrationRevocations
    /// Read live: once when the cue starts (before any cache key, reservation or provider call),
    /// then again by `mayUse` at each #400 gate (before and after an off-device route's cache
    /// read, inside the timed provider task, before and after its cache write), so a consent
    /// change applies mid-cue, not only from the next line. Every narrowed view shares it.
    public let cloudScope: @Sendable () -> CloudVoiceScope

    public init(routes: [VoiceRoute], budget: VoiceBudget, cache: any AudioCache,
                revocations: NarrationRevocations = .shared,
                cloudScope: @escaping @Sendable () -> CloudVoiceScope = { .transitionsOnly }) {
        self.routes = routes
        self.budget = budget
        self.cache = cache
        self.revocations = revocations
        self.cloudScope = cloudScope
    }

    /// This renderer's budget, cache, revocations and scope over `routes`.
    func narrowed(to routes: [VoiceRoute]) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: budget, cache: cache, revocations: revocations, cloudScope: cloudScope)
    }

    /// Tag on every clip of a line that only the wider scope (`.allLines`) lets leave the device,
    /// so "Delete my DJ data" (`purgeAllPersonal`) and a purge-all in flight find it even when the
    /// line has no `sourceItemID` (a library track, a typed station name). The launch purge
    /// (`purgePersonalItems`) keeps a clip with only this tag, so it isn't paid for again.
    /// Not a real item id; never logged. -Fry
    public static let allLinesClipTag = UUID(uuidString: "A11C10D0-0000-4000-8000-00000000F2A1")!

    /// The last route alone (the on-device standard voice), sharing this renderer's budget,
    /// cache and revocations. Nil when there is only one route, or when the last route is paid
    /// or leaves the device (Sentinel, #154). `DJBreakPreparer` uses it to re-render a break
    /// that ran over its cap; it is a narrowed view, not a second renderer.
    public var lastRouteOnly: VoiceRenderer? {
        guard routes.count > 1, let last = routes.last, last.isLocalAndFree else { return nil }
        return narrowed(to: [last])
    }

    /// Only the on-device, free routes, in order, sharing this renderer's budget, cache and
    /// revocations. Nil when there are none. Used for breaks on a station with a library seed:
    /// the listener's own library never goes to a cloud or paid voice. A narrowed view, not a
    /// second renderer.
    public var onDeviceOnly: VoiceRenderer? {
        let local = routes.filter(\.isLocalAndFree)
        guard !local.isEmpty else { return nil }
        return narrowed(to: local)
    }

    /// Cloud-voice consent withdrawn (Echo's N2 on #395): deletes every cached clip that was not
    /// rendered by one of this renderer's on-device, free routes, so a cloud clip is never served
    /// again from the cache (the cache is read before a route's provider, and so before the tester
    /// route's consent check). On-device clips stay. -Nova
    public func purgeCloudClips() async {
        await cache.purgeClips(keepingProviders: Set(routes.filter(\.isLocalAndFree).map(\.providerID)))
    }

    /// Attempt detail for an off-device or paid route skipped for a local-only cue. Fixed text, no cue text.
    public static let localOnlySkip = "local-only cue: off-device route skipped"

    public static func cacheKey(text: String, route: VoiceRoute) -> String {
        SHA256Digest.hex([cacheFormatVersion, route.providerID, route.voice.id, route.acceptsSSML ? "ssml" : "text", text]
            .joined(separator: "\u{1F}"))
    }

    /// The cache key with stitching context. A line voiced after one line and before another is
    /// a different take from the same words in another break, so the context is part of the key.
    /// With no context it is exactly `cacheKey(text:route:)`, so existing clips keep their keys.
    public static func cacheKey(text: String, route: VoiceRoute, context: SpeechNeighbours) -> String {
        guard !context.isEmpty else { return cacheKey(text: text, route: route) }
        return SHA256Digest.hex([cacheFormatVersion, route.providerID, route.voice.id, route.acceptsSSML ? "ssml" : "text", text,
                                 "prev", context.previous ?? "", "next", context.next ?? ""]
            .joined(separator: "\u{1F}"))
    }

    /// The neighbouring lines of `cue` in `cues` (one break, in air order) that may be sent as
    /// stitching context. Each side is included only when that neighbour itself passes
    /// `mayLeaveDevice` with its own attribution and `scope` — the same per-cue rule that decides
    /// whether the neighbour's own render may leave the device (#176). An ineligible neighbour is
    /// omitted; the other side is still sent. This does not widen that rule: `.noLines` and
    /// `.transitionsOnly` stay as they are, and `.allLines` is the only scope that lets more cues
    /// through, by the same check. Included neighbours carry their item ids, and
    /// `needsAllLinesTag` when one of them may leave only under `.allLines`, so a purge of that
    /// item (or a purge-all) covers the clip that quoted it. Empty when `cue` is not in `cues`.
    public static func neighbours(of cue: NarrationCue, in cues: [NarrationCue],
                                  attributions: [UUID: SpokenAttribution],
                                  scope: CloudVoiceScope = .transitionsOnly) -> SpeechNeighbours {
        contextNeighbours(of: cue, in: cues, attributions: attributions, scope: scope).context
    }

    /// `neighbours(of:in:attributions:scope:)` plus the privacy class of each included neighbour
    /// (`CuePrivacy.classify`, the same rule as the cue's own), so #400 gate 2 can re-check them
    /// against the live scope right before their text is sent.
    static func contextNeighbours(of cue: NarrationCue, in cues: [NarrationCue],
                                  attributions: [UUID: SpokenAttribution],
                                  scope: CloudVoiceScope) -> (context: SpeechNeighbours, privacy: [CuePrivacyClass]) {
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return (.none, []) }
        struct Side {
            let text: String
            let itemID: UUID?
            let needsAllLines: Bool
            let privacy: CuePrivacyClass
        }
        func side(at i: Int) -> Side? {
            guard cues.indices.contains(i) else { return nil }
            let neighbour = cues[i]
            let privacy = CuePrivacy.classify(neighbour, attribution: attributions[neighbour.id])
            guard privacy.mayLeaveDevice(scope: scope) else { return nil }
            let text = neighbour.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let widened = !privacy.mayLeaveDevice(scope: .transitionsOnly)
            return Side(text: text, itemID: neighbour.sourceItemID, needsAllLines: widened, privacy: privacy)
        }
        let previous = side(at: index - 1), next = side(at: index + 1)
        let context = SpeechNeighbours(previous: previous?.text, next: next?.text,
                                       sourceItemIDs: [previous?.itemID, next?.itemID].compactMap { $0 },
                                       needsAllLinesTag: (previous?.needsAllLines ?? false) || (next?.needsAllLines ?? false))
        return (context, [previous?.privacy, next?.privacy].compactMap { $0 })
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
    /// Missing attribution, `.personalContext`, `.stationName` (a created station's name), any sourced or briefing cue (Calendar, Share,
    /// Obsidian, library notes…) or a cue whose fields disagree with its attribution is local-only.
    ///
    /// Track metadata is eligible only when every named track is `.catalog` (Sentinel): a track
    /// from the listener's library, or one of `.unknown` origin, is personal and stays on-device,
    /// even on a catalog station (main segment and closing line alike).
    /// #200 (-Echo, Sentinel's #401 B1): a clip may go in the narration cache only if a purge can
    /// find it. A provider-fact line (local news, weather: `FactProvenance`) or any other expiring
    /// line with no `sourceItemID` would sit there untagged, so `purgeAllPersonal` and a location
    /// withdrawal could not remove it for up to the 7-day cache life. Such a cue is never looked
    /// up in or written to the cache: it renders fresh, and lives only in the prepared break.
    public static func mayUseCache(_ cue: NarrationCue) -> Bool {
        if FactProvenance.isFact(cue.provenance) { return false }
        return cue.expiresAt == nil || cue.sourceItemID != nil
    }

    /// `scope` (owner, Nov 9 2026): `.transitionsOnly` is the rule above; `.noLines` keeps every
    /// cue local; `.allLines` (consent to copy v3, #432) lets every attributed cue go. A cue with no
    /// attribution is local-only whatever the scope.
    /// #400: the same rule, now read from the cue's one privacy class (`CuePrivacy.classify`).
    public static func mayLeaveDevice(_ cue: NarrationCue, attribution: SpokenAttribution?,
                                      scope: CloudVoiceScope = .transitionsOnly) -> Bool {
        CuePrivacy.classify(cue, attribution: attribution).mayLeaveDevice(scope: scope)
    }

    /// #400 (-Sentinel): the one per-cue choke point. An on-device, free route is always usable.
    /// Any other route is usable only while a cue of class `privacy` may leave the device under
    /// the consent scope read now (`cloudScope()`, live). `render` asks it immediately before
    /// and after that route's cache lookup, immediately before its provider call (inside the timed task),
    /// and immediately before and after its cache write, so a decline that lands mid-render stops
    /// the next step: no text is sent, no clip is cached or served, and the cue falls through to
    /// the on-device route.
    public func mayUse(_ route: VoiceRoute, for privacy: CuePrivacyClass) -> Bool {
        route.isLocalAndFree || privacy.mayLeaveDevice(scope: cloudScope())
    }

    /// #400 gate 2 for stitching context: every quoted neighbour may still leave the device under
    /// the consent scope read now. A neighbour that became local-only mid-render (e.g. all lines
    /// narrowed to transitions only) refuses the route, so its text is never sent. -Sentinel
    func mayQuote(_ neighbours: [CuePrivacyClass]) -> Bool {
        let live = cloudScope()
        return neighbours.allSatisfy { $0.mayLeaveDevice(scope: live) }
    }

    /// Attempt detail when the choke point refused a route mid-render. Fixed text, no cue text.
    public static let privacyGateSkip = "cue no longer eligible: off-device route skipped"

    /// Thrown inside the timed provider task when the choke point refuses just before the call.
    struct PrivacyGateRefusal: Error {}

    /// Renders `cue` on the first route that succeeds. Unless `mayLeaveDevice(cue, attribution:)`
    /// holds, only `isLocalAndFree` routes are used: any route that leaves the device or is paid
    /// (even one built without `leavesDevice`) is skipped, never looked up in the cache, reserved
    /// against or called. With no attribution the cue is local-only, and if no local, free route
    /// exists it fails closed with `.renderFailed`; it never falls back to cloud or a paid voice.
    ///
    /// `breakCues` / `breakAttributions` are the cue's break, in air order. A route with
    /// `sendsSpeechContext` receives each neighbouring line as stitching context only when this
    /// cue and that neighbour both pass `mayLeaveDevice` under this renderer's `cloudScope`.
    /// Empty `breakCues` (every caller that is not a break) sends no context, and the request
    /// body and cache key stay as they were.
    public func render(_ cue: NarrationCue, userID: String, stationID: String,
                       attribution: SpokenAttribution? = nil,
                       breakCues: [NarrationCue] = [],
                       breakAttributions: [UUID: SpokenAttribution] = [:]) async -> Result<RenderedClip, Failure> {
        var attempts: [VoiceAttempt] = []
        // Decided once, before any cache key, reservation or provider call (#176). Ineligible
        // cues use `isLocalAndFree` routes only.
        let privacy = CuePrivacy.classify(cue, attribution: attribution)
        let scope = cloudScope()
        let offDeviceAllowed = privacy.mayLeaveDevice(scope: scope)
        let widened = offDeviceAllowed && !privacy.mayLeaveDevice(scope: .transitionsOnly)
        // Neighbours are decided with the same scope, before the purge check. A context-sending
        // route quotes their text, so their item ids (and `allLinesClipTag` when one of them may
        // leave only under `.allLines`) have to be in `sources` or a purge of that item, including
        // a purge-all still in flight, cannot see the clip. -Echo
        let (mates, matePrivacy) = Self.contextNeighbours(of: cue, in: breakCues, attributions: breakAttributions, scope: scope)
        var sourceList = (cue.sourceItemID.map { [$0] } ?? []) + (widened ? [Self.allLinesClipTag] : [])
        if offDeviceAllowed, routes.contains(where: \.sendsSpeechContext), !mates.isEmpty {
            for id in mates.sourceItemIDs where !sourceList.contains(id) { sourceList.append(id) }
            if mates.needsAllLinesTag, !sourceList.contains(Self.allLinesClipTag) { sourceList.append(Self.allLinesClipTag) }
        }
        let sources = sourceList
        let token = revocations.token()  // before any synthesis: a later purge of `sources` wins
        if revocations.purgePending(sources) {
            // A purge of this item is still running: render nothing that it could miss.
            return .failure(Failure(reason: .renderFailed, attempts: [VoiceAttempt(providerID: routes.first?.providerID ?? "", result: .cancelled)]))
        }
        let useCache = Self.mayUseCache(cue)
        for route in routes {
            if !route.isLocalAndFree && !offDeviceAllowed {
                // Local-only cue: its text never reaches this off-device or paid route, its cache
                // keys or its budget (Echo: a paid route without `leavesDevice` is not local).
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.localOnlySkip)))
                continue
            }
            if !mayUse(route, for: privacy) {
                // #400 gate 1 (lookup): consent changed since the cue started. Neither this route's
                // cache nor its provider is touched.
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.privacyGateSkip)))
                continue
            }
            if Task.isCancelled { return .failure(Failure(reason: .renderFailed, attempts: attempts + [VoiceAttempt(providerID: route.providerID, result: .cancelled)])) }
            let text = Self.spokenText(cue.text, for: route)
            // Same `mates` as the purge check above. A local-only cue sends nothing, and a
            // neighbour is included only when it may leave the device itself.
            let speech = route.sendsSpeechContext && offDeviceAllowed ? mates.spoken() : .none
            let key = Self.cacheKey(text: text, route: route, context: speech)
            if useCache, let cached = await cache.audio(for: key), cached.seconds <= Double(cue.maxSeconds) {
                // Keys are text + voice, so the clip may carry other items' ids: check both.
                guard mayUse(route, for: privacy) else {
                    // #400 gate 1b (after the read; Atlas's B1 on #498): consent was withdrawn while the
                    // read was in flight. A plain decline revokes no item id, so the revocation check
                    // below would pass: never hand back this cloud clip; fall through to the on-device route.
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.privacyGateSkip)))
                    continue
                }
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
            let request = RequestContext(stationID: stationID, isReusableGeneric: false,
                                         previousText: speech.previous, nextText: speech.next)
            do {
                let renderer = self
                let artifact = try await Self.withTimeout(route.timeout) {
                    // #400 gate 2 (TTS): checked last, right before the text is handed to the provider.
                    // When neighbour text rides along as context, every quoted neighbour must still
                    // be allowed off the device under the live scope too, or nothing is sent.
                    guard renderer.mayUse(route, for: privacy),
                          speech.isEmpty || renderer.mayQuote(matePrivacy) else { throw PrivacyGateRefusal() }
                    return try await route.provider.synthesize(text, voice: route.voice, context: request)
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
                                        sourceItemIDs: sources)
                if Task.isCancelled || revocations.revoked(sources, since: token) {
                    // The caller gave up, or the source was purged mid-render: nothing is cached or returned.
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                    return .failure(Failure(reason: .renderFailed, attempts: attempts))
                }
                guard mayUse(route, for: privacy) else {
                    // #400 gate 3 (cache write): consent withdrawn while the provider ran. The clip
                    // is neither cached nor returned; the cue falls through to the on-device route.
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.privacyGateSkip)))
                    continue
                }
                if useCache {
                    await cache.store(audio, for: key)
                    if !mayUse(route, for: privacy) {
                        // Withdrawn while the write was in flight; the decline's own purge may have
                        // run before it. Remove off-device clips again and do not return this one.
                        // Deliberately fail-closed (Echo's nit on #498): this drops every off-device
                        // clip, including transition clips still allowed when the scope only narrows
                        // from all lines to transitions only; those just render again.
                        await purgeCloudClips()
                        attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.privacyGateSkip)))
                        continue
                    }
                }
                if revocations.revoked(sources, since: token) {
                    // A purge landed while the write was in flight and may have run before it:
                    // remove what we just wrote. (A purge after the write removes it itself.)
                    await cache.purge(sourceItemIDs: Set(sources))
                    attempts.append(VoiceAttempt(providerID: route.providerID, result: .cancelled))
                    return .failure(Failure(reason: .renderFailed, attempts: attempts))
                }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .rendered))
                return .success(RenderedClip(cueID: cue.id, audio: audio, cacheKey: key, attempts: attempts))
            } catch is PrivacyGateRefusal {
                // Refused before the call: nothing was sent or billed.
                if let r = reservation { await budget.release(r) }
                attempts.append(VoiceAttempt(providerID: route.providerID, result: .failed(Self.privacyGateSkip)))
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

    /// The text a route receives. A route that leaves the device gets plain text with every `[`
    /// and `]` stripped (an allowlisted audio tag kept only when `supportsAudioTags` is on), or
    /// SSML of that text when the route accepts SSML. Any other route gets the same SSML or
    /// `speakable` text as before. Bracket-free text is unchanged, so its cache key is too.
    public static func spokenText(_ text: String, for route: VoiceRoute) -> String {
        if route.leavesDevice {
            let plain = SpeechDelivery.speakable(text, keepingAudioTags: route.supportsAudioTags)
            return route.acceptsSSML ? SpeechDelivery.ssml(plain) : plain
        }
        return route.acceptsSSML ? SpeechDelivery.ssml(text) : SpeechDelivery.speakable(text)
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

/// The spoken neighbours of one line in its break: stitching context for a voice that uses it.
public struct SpeechNeighbours: Equatable, Sendable {
    public let previous: String?
    public let next: String?
    /// Item ids of the neighbours whose text is included. A purge of one of these finds the clip.
    public let sourceItemIDs: [UUID]
    /// An included neighbour may leave the device only under `.allLines`, so the clip also carries
    /// `VoiceRenderer.allLinesClipTag` and a purge-all can find it.
    public let needsAllLinesTag: Bool
    public static let none = SpeechNeighbours(previous: nil, next: nil)

    public init(previous: String?, next: String?, sourceItemIDs: [UUID] = [], needsAllLinesTag: Bool = false) {
        self.previous = previous
        self.next = next
        self.sourceItemIDs = sourceItemIDs
        self.needsAllLinesTag = needsAllLinesTag
    }

    public var isEmpty: Bool { (previous ?? "").isEmpty && (next ?? "").isEmpty }

    /// Plain text with brackets removed. Context never carries audio tags, even on a route that
    /// would keep an allowlisted tag in the line it speaks. Purge tags are kept.
    func spoken() -> SpeechNeighbours {
        func plain(_ t: String?) -> String? {
            guard let t else { return nil }
            let s = SpeechDelivery.speakable(t, keepingAudioTags: false)
            return s.isEmpty ? nil : s
        }
        return SpeechNeighbours(previous: plain(previous), next: plain(next),
                                sourceItemIDs: sourceItemIDs, needsAllLinesTag: needsAllLinesTag)
    }
}
