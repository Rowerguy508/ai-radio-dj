import Foundation

// App Attest on the device, behind a protocol (#378, -Atlas).
//
// The app target's `DCAppAttestService` adapter (`AppAttestService+App.swift`, compiled only
// `#if canImport(DeviceCheck)`) conforms to this. Linux tests use fakes. Nothing here imports
// DeviceCheck, so the state machine that drives it (`InstallTokenSource`) is Linux-testable.

/// What a device App Attest call failed with, mapped from `DCError` by the adapter.
/// No payload: nothing about a key, a challenge or an attestation can ride along in a log line.
public enum AppAttestDeviceError: Error, Equatable, Sendable {
    /// `DCError.featureUnsupported`, the simulator, or `isSupported == false`.
    case unsupported
    /// `DCError.invalidKey`: the key is gone or unusable (reinstall, restore, OS reset).
    /// The source discards its key ID and regenerates once per launch.
    case invalidKey
    /// `DCError.serverUnavailable`: Apple's attestation service is unreachable. Transient.
    case serverUnavailable
    /// Anything else (`invalidInput`, `unknownSystemFailure`, an unknown code).
    case failed
}

/// The device side of App Attest. Every method may be slow (Secure Enclave, Apple's servers),
/// so the source calls them only off the playback path: enrollment runs in a background task,
/// and an assertion is made only while a break is being prepared.
public protocol AppAttestDevice: Sendable {
    /// `DCAppAttestService.shared.isSupported`. False on the simulator and unsupported devices.
    var isSupported: Bool { get }
    /// A new Secure Enclave key. Returns its key ID: standard base64 of SHA-256(public key), 44 chars.
    func generateKey() async throws -> String
    /// The attestation object (CBOR) for `keyId` over `clientDataHash`.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    /// An assertion (CBOR `{signature, authenticatorData}`) for `keyId` over `clientDataHash`.
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// For builds and platforms without App Attest: unsupported, every call throws.
public struct UnsupportedAppAttestDevice: AppAttestDevice {
    public init() {}
    public var isSupported: Bool { false }
    public func generateKey() async throws -> String { throw AppAttestDeviceError.unsupported }
    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw AppAttestDeviceError.unsupported }
    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AppAttestDeviceError.unsupported
    }
}

/// SHA-256 helpers for the attest contract (Linux-safe; `SHA256Digest`, no CryptoKit).
public enum AttestHash {
    /// SHA-256 of `bytes`.
    public static func sha256(_ bytes: Data) -> Data { Data(SHA256Digest.hash([UInt8](bytes))) }

    /// Lowercase hex SHA-256 of `bytes`.
    public static func sha256Hex(_ bytes: Data) -> String {
        sha256(bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The register `clientDataHash`: SHA-256 of the challenge's UTF-8 bytes
    /// (server `attestClientDataHash(challenge)`, app-attest-verify.ts).
    public static func attestClientDataHash(challenge: String) -> Data { sha256(Data(challenge.utf8)) }
}
