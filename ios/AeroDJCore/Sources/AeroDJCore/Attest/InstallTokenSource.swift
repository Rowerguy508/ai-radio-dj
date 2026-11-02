import Foundation

/// Hands the voice proxy a current install token (#378 §1.3). `ProxyVoiceProvider` calls it
/// only while a break is being prepared, inside the route's timeout.
public protocol InstallTokenProviding: Sendable {
    /// A token with more than `InstallTokenSource.refreshMargin` left, or a fresh one. Throws
    /// `InstallTokenSource.Unavailable` (an enum, no payload) when there is none right now; the
    /// renderer then uses the on-device voice for that cue.
    func installToken() async throws -> InstallToken
    /// The proxy answered 401 `token_expired` for `token`: drop it so the next call mints anew.
    func tokenRejected(_ token: InstallToken) async
}

/// The App Attest client's state machine (#378, -Atlas). Pure logic, Linux-tested with fakes;
/// the device (`AppAttestDevice`) and HTTP (`HTTPTransport`) sit behind protocols.
///
/// Flow:
/// 1. **Consent and support first.** No consent (`PaidVoiceConsentProviding`), or an unsupported
///    device or the simulator: `Unavailable`, with no Keychain read, device call or request.
/// 2. **Enroll** (no registered key): runs in a background task and the cue goes on-device at
///    once, so playback never waits on attestation. generateKey → `attest` challenge bound to the
///    key → attestKey(SHA-256(challenge)) → register `{keyId, attestationObject, challenge,
///    installId}` (#277's `AttestClient`). Only a 204 saves the key ID (Keychain, this device only).
///    At most once per launch, plus one regeneration after an invalidated key.
/// 3. **Mint** (registered key, no token with more than 5 minutes left): `tok` challenge →
///    assertion over `"onairly-tok-v1\n" + challenge + "\n" + hex(sha256(body))` → token,
///    cached in memory only. One retry on 400 `challenge_expired`. Concurrent callers share one
///    mint. With under 5 minutes but at least 1 minute left, the cue uses the current token and
///    the refresh runs in the background; only a cue with no usable token waits for a mint
///    (bounded by the request timeouts and the route's 16 s timeout).
/// 4. **Invalidated key** (device `invalidKey`, or 401 `reattest`): forget the key ID and enroll a
///    new key once this launch; a second time stops the paid route until the next launch.
///
/// Every failure is quiet and lands in the shared `PaidVoiceBackoff`, which the provider checks
/// before any token read: 429 → `Retry-After` (else the reason's default), 503 → `Retry-After`,
/// 5xx and transport → exponential, everything else (assertion, `no_entitlement`, a malformed
/// answer, a device failure) → stop until the next launch. Logs are enums and status codes only:
/// never a token, key ID, challenge, assertion, attestation or install ID.
public actor InstallTokenSource: InstallTokenProviding {
    public enum Unavailable: Error, Equatable, Sendable {
        case noConsent, unsupported, enrolling, keyUnreadable, backingOff, stopped, failed
    }

    /// One log line: an event, an outcome enum's raw value and a status code. Nothing else.
    public struct LogEntry: Equatable, Sendable {
        public enum Event: String, Sendable { case enroll, mint, reattest }
        public let event: Event
        /// Always an enum's `rawValue` (`InstallTokenClient.Failure.Reason`, `AttestClient.Failure.Reason`,
        /// `AppAttestDeviceError`) or `ok`; never free text.
        public let outcome: String
        public let status: Int?
    }

    /// Mint a new token when less than this is left (#378 §1.3: 5 minutes).
    public static let refreshMargin: TimeInterval = 5 * 60
    /// A token with at least this left still goes out if a refresh fails or is backing off.
    public static let minimumUsableLifetime: TimeInterval = 60

    private let device: any AppAttestDevice
    private let keyStore: any AttestKeyIDStorage
    private let attest: AttestClient
    private let tokens: InstallTokenClient
    private let consent: any PaidVoiceConsentProviding
    private let backoff: PaidVoiceBackoff
    private let now: @Sendable () -> Date
    private let log: @Sendable (LogEntry) -> Void

    private var cached: InstallToken?
    /// A key registered this launch whose Keychain save failed: usable until the next launch.
    private var memoryKeyID: String?
    private var enrollTask: Task<Void, Never>?
    private var mintTask: Task<InstallToken, Error>?
    private var mintGeneration = 0
    private var enrollmentsThisLaunch = 0
    private var regenerationUsed = false

    public init(device: any AppAttestDevice, keyStore: any AttestKeyIDStorage, attest: AttestClient,
                tokens: InstallTokenClient, consent: any PaidVoiceConsentProviding, backoff: PaidVoiceBackoff,
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        self.device = device
        self.keyStore = keyStore
        self.attest = attest
        self.tokens = tokens
        self.consent = consent
        self.backoff = backoff
        self.now = now
        self.log = log
    }

    // MARK: Public

    public func installToken() async throws -> InstallToken {
        guard await consent.hasPaidVoiceConsent() else { throw Unavailable.noConsent }
        guard device.isSupported else { throw Unavailable.unsupported }
        if let token = cached, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token }
        if backoff.suspendedUntil() != nil {
            if let token = usableCached() { return token }
            throw Unavailable.backingOff
        }
        let keyId: String
        switch currentKeyID() {
        case .found(let id): keyId = id
        case .notFound:
            startEnrollmentIfAllowed()
            throw Unavailable.enrolling
        case .failed:
            throw Unavailable.keyUnreadable
        }
        let task = mintTask ?? startMint(keyId: keyId)
        // Inside the refresh window with time left: this cue keeps the current token and the
        // refresh finishes in the background, so a break never waits on it.
        if let token = usableCached() { return token }
        do {
            return try await task.value
        } catch {
            if let token = usableCached() { return token }
            throw (error as? Unavailable) ?? Unavailable.failed
        }
    }

    /// One mint at a time; concurrent and background callers share it.
    private func startMint(keyId: String) -> Task<InstallToken, Error> {
        mintGeneration += 1
        let generation = mintGeneration
        let task = Task {
            do {
                let token = try await self.mint(keyId: keyId)
                self.mintFinished(generation)
                return token
            } catch {
                self.mintFinished(generation)
                throw error
            }
        }
        mintTask = task
        return task
    }

    private func mintFinished(_ generation: Int) {
        if generation == mintGeneration { mintTask = nil }
    }

    public func tokenRejected(_ token: InstallToken) async {
        if cached == token { cached = nil }
    }

    /// Starts enrollment in the background if there is consent, a supported device and no key.
    /// For launch and right after the consent sheet, so the first break can already use the cloud
    /// voice. Returns at once; never waits on attestation.
    public func prepare() async {
        guard await consent.hasPaidVoiceConsent(), device.isSupported, backoff.suspendedUntil() == nil else { return }
        if case .notFound = currentKeyID() { startEnrollmentIfAllowed() }
    }

    /// Test seam: waits for a running enrollment.
    func waitForEnrollment() async { await enrollTask?.value }

    /// Test seam: waits for a running (background) mint.
    func waitForMint() async { _ = try? await mintTask?.value }

    // MARK: Key

    private func currentKeyID() -> AttestKeyIDRead {
        if let memoryKeyID { return .found(memoryKeyID) }
        switch keyStore.readKeyID() {
        case .found(let id) where AttestKeyID.isValid(id): return .found(id)
        case .found:
            keyStore.clearKeyID()  // not a key ID we could have saved: start over
            return .notFound
        case let other: return other
        }
    }

    private func usableCached() -> InstallToken? {
        guard let token = cached, token.expiresAt.timeIntervalSince(now()) >= Self.minimumUsableLifetime else { return nil }
        return token
    }

    /// One enrollment at a time; at most one per launch, plus one regeneration.
    private func startEnrollmentIfAllowed() {
        let allowed = regenerationUsed ? 2 : 1
        guard enrollTask == nil, enrollmentsThisLaunch < allowed, backoff.suspendedUntil() == nil else { return }
        enrollmentsThisLaunch += 1
        enrollTask = Task {
            await self.enroll()
            self.enrollFinished()
        }
    }

    private func enrollFinished() { enrollTask = nil }

    private func enroll() async {
        let keyId: String
        do { keyId = try await device.generateKey() } catch { deviceFailed(error, .enroll); return }
        guard AttestKeyID.isValid(keyId) else {
            record(.enroll, "unexpected", nil)
            backoff.recordAttestFailure()
            return
        }
        let challenge: String
        switch await attest.challenge(keyId: keyId) {
        case .failure(let failure): registerFailed(failure); return
        case .success(let value): challenge = value
        }
        let attestation: Data
        do {
            attestation = try await device.attestKey(keyId, clientDataHash: AttestHash.attestClientDataHash(challenge: challenge))
        } catch { deviceFailed(error, .enroll); return }
        switch await attest.register(keyId: keyId, attestationObject: attestation.base64EncodedString(), challenge: challenge) {
        case .failure(let failure): registerFailed(failure)
        case .success:
            memoryKeyID = keyStore.saveKeyID(keyId) ? nil : keyId
            record(.enroll, "ok", 204)
        }
    }

    /// The key is gone (device `invalidKey`, server `reattest`): forget it and enroll once more
    /// this launch. A second invalidation stops the paid route until the next launch.
    private func reattest() {
        keyStore.clearKeyID()
        memoryKeyID = nil
        cached = nil
        if regenerationUsed {
            record(.reattest, "stopped", nil)
            backoff.recordAttestFailure()
        } else {
            regenerationUsed = true
            record(.reattest, "regenerate", nil)
            startEnrollmentIfAllowed()
        }
    }

    // MARK: Mint

    private func mint(keyId: String) async throws -> InstallToken {
        for attempt in 0..<2 {
            let challenge: String
            switch await tokens.challenge(keyId: keyId) {
            case .failure(let failure): throw tokenFailed(failure)
            case .success(let value): challenge = value
            }
            guard let body = InstallTokenClient.tokenBody(challenge: challenge) else {
                throw tokenFailed(.init(reason: .unexpected, status: 200, retryAfter: nil))
            }
            let assertion: Data
            do {
                assertion = try await device.generateAssertion(
                    keyId, clientDataHash: InstallTokenClient.assertionClientDataHash(challenge: challenge, body: body))
            } catch {
                throw deviceFailed(error, .mint)
            }
            switch await tokens.mint(keyId: keyId, body: body, assertion: assertion, startedAt: now()) {
            case .success(let token):
                cached = token
                record(.mint, "ok", 200)
                return token
            case .failure(let failure) where failure.reason == .challengeExpired && attempt == 0:
                record(.mint, failure.reason.rawValue, failure.status)  // one fresh challenge, then give up
                continue
            case .failure(let failure):
                throw tokenFailed(failure)
            }
        }
        throw Unavailable.failed
    }

    // MARK: Failure policy

    @discardableResult
    private func deviceFailed(_ error: Error, _ event: LogEntry.Event) -> Unavailable {
        if error is CancellationError || Task.isCancelled { return .failed }
        let deviceError = (error as? AppAttestDeviceError) ?? .failed
        record(event, "device_\(deviceError)", nil)
        switch deviceError {
        case .serverUnavailable:
            backoff.recordServerFailure()
            return .backingOff
        case .invalidKey where event == .mint:
            reattest()
            return .enrolling
        case .unsupported, .invalidKey, .failed:
            backoff.recordAttestFailure()
            return .stopped
        }
    }

    /// Register or `attest` challenge failures (#277's mapping). A failed enrollment keeps no key.
    private func registerFailed(_ failure: AttestClient.Failure) {
        if Task.isCancelled { return }
        record(.enroll, failure.reason.rawValue, failure.status)
        let retryAfter = failure.retryAfterSeconds.map(String.init)
        switch failure.reason {
        case .enroll:
            backoff.recordRateLimited(retryAfter: retryAfter, reason: .enroll)
        case .disabled:
            backoff.recordServiceUnavailable(retryAfter: retryAfter, reason: .disabled)
        case .store:
            backoff.recordServiceUnavailable(retryAfter: retryAfter, reason: .store)
        case .misconfig:
            backoff.recordServiceUnavailable(retryAfter: retryAfter, reason: nil)
        case .transport:
            backoff.recordServerFailure()
        case .challengeExpired:
            break  // the attestation took over 120 s: nothing is kept, the next launch tries again
        case .badRequest, .tooLarge, .assertion, .network, .install, .noInstallID, .unexpected:
            backoff.recordAttestFailure()
        }
    }

    private func tokenFailed(_ failure: InstallTokenClient.Failure) -> Unavailable {
        if Task.isCancelled { return .failed }
        record(.mint, failure.reason.rawValue, failure.status)
        switch failure.reason {
        case .reattest:
            reattest()
            return .enrolling
        case .rate:
            backoff.recordRateLimited(retryAfter: failure.retryAfter, reason: .rate)
            return .backingOff
        case .disabled:
            backoff.recordServiceUnavailable(retryAfter: failure.retryAfter, reason: .disabled)
            return .backingOff
        case .store:
            backoff.recordServiceUnavailable(retryAfter: failure.retryAfter, reason: .store)
            return .backingOff
        case .misconfig:
            backoff.recordServiceUnavailable(retryAfter: failure.retryAfter, reason: nil)
            return .backingOff
        case .transport:
            backoff.recordServerFailure()
            return .backingOff
        case .challengeExpired:
            return .failed
        case .noEntitlement:
            // Not a TestFlight tester install (#378 §1.5): no free voice in this launch.
            backoff.recordUnauthorized()
            return .stopped
        case .assertion, .badRequest, .mixedAuth, .tooLarge, .unexpected:
            backoff.recordAttestFailure()
            return .stopped
        }
    }

    private func record(_ event: LogEntry.Event, _ outcome: String, _ status: Int?) {
        log(LogEntry(event: event, outcome: outcome, status: status))
    }
}
