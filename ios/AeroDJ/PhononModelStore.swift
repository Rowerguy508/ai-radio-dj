import Foundation
import os

/// First-run download of the pinned Phonon 31m Core ML zip. The zip is not in the
/// app bundle. Rendered clips still go through `VoiceRenderer`'s cache (7 days,
/// consent purge). This directory is weights, not narration, so the sweeper does
/// not delete it.
enum PhononModelPaths {
    static func root() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phonon31m", isDirectory: true)
            .appendingPathComponent(PhononModelPin.weightsCommit, isDirectory: true)
    }

    static func archive() -> URL { root().appendingPathComponent("phonon-31m-en-coreml.zip") }
    static func bundle() -> URL { root().appendingPathComponent("bundle", isDirectory: true) }
    static func marker() -> URL { bundle().appendingPathComponent(".phonon-pin") }
}

actor PhononModelCoordinator {
    static let shared = PhononModelCoordinator()
    private var current: PhononModelStatus = .missing
    private var started = false
    private let log = Logger(subsystem: "com.aerodj.app", category: "phonon")

    func status() -> PhononModelStatus { current }

    func start() {
        guard !started else { return }
        started = true
        Task.detached {
            let status = await PhononModelStore.install()
            await PhononModelCoordinator.shared.finish(status)
        }
    }

    private func finish(_ status: PhononModelStatus) {
        current = status
        log.info("phonon model status=\(status.rawValue, privacy: .public)")
    }
}

enum PhononModelStore {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "phonon")

    static func install() async -> PhononModelStatus {
        guard PhononSpeechRuntime.isAvailable else { return .unsupportedRuntime }
        guard PhononModelPin.allowsDownload(PhononModelPin.bundleURL) else { return .rejectedBundle }
        let fm = FileManager.default
        let root = PhononModelPaths.root()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
        } catch {
            return .downloadFailed
        }
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)

        if verdict(of: PhononModelPaths.archive()) != .match {
            try? fm.removeItem(at: PhononModelPaths.archive())
            try? fm.removeItem(at: PhononModelPaths.bundle())
            switch await download() {
            case .match: break
            case .deferred: return .deferred
            case .missing: return .downloadFailed
            case .mismatch:
                try? fm.removeItem(at: PhononModelPaths.archive())
                try? fm.removeItem(at: PhononModelPaths.bundle())
                return .hashMismatch
            }
        }
        guard verdict(of: PhononModelPaths.archive()) == .match else {
            try? fm.removeItem(at: PhononModelPaths.archive())
            try? fm.removeItem(at: PhononModelPaths.bundle())
            return .hashMismatch
        }
        guard extractIfNeeded() else {
            try? fm.removeItem(at: PhononModelPaths.bundle())
            return .rejectedBundle
        }
        guard sourceAccepted() else {
            try? fm.removeItem(at: PhononModelPaths.bundle())
            return .rejectedBundle
        }
        guard #available(iOS 18, *) else { return .unsupportedRuntime }
        let code = await PhononEngineClient.prepare(directory: PhononModelPaths.bundle().path, voice: PhononModelPin.voiceID)
        log.info("phonon prepare code=\(code, privacy: .public)")
        switch code {
        case 0: return .ready
        case 3: return .voiceMissing
        default: return .loadFailed
        }
    }

    private static func verdict(of url: URL) -> PhononBundleDigest.Verdict {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PhononBundleDigest.verdict(byteCount: nil, sha256: nil)
        }
        let count = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        let digest = try? PhononBundleDigest.sha256Hex(ofFile: url)
        return PhononBundleDigest.verdict(byteCount: count, sha256: digest)
    }

    private static func fetch(_ verdict: PhononBundleDigest.Verdict) -> Fetch {
        switch verdict {
        case .match: return .match
        case .missing: return .missing
        case .mismatch: return .mismatch
        }
    }

    private enum Fetch: Equatable {
        case match
        case missing
        case mismatch
        case deferred
    }

    private static func download() async -> Fetch {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [:]
        // Wi-Fi only. Cellular and Low Data Mode (constrained) wait for a later launch.
        config.allowsCellularAccess = PhononModelDownloadPolicy.allowsCellularAccess
        config.allowsExpensiveNetworkAccess = PhononModelDownloadPolicy.allowsExpensiveNetworkAccess
        config.allowsConstrainedNetworkAccess = PhononModelDownloadPolicy.allowsConstrainedNetworkAccess
        var request = URLRequest(url: PhononModelPin.bundleURL)
        request.httpMethod = "GET"
        request.httpBody = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (temp, response) = try await session.download(for: request, delegate: PhononDownloadGate())
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.info("phonon download http=\(http, privacy: .public)")
            guard (200..<300).contains(http) else {
                try? FileManager.default.removeItem(at: temp)
                return .missing
            }
            let checked = verdict(of: temp)
            guard checked == .match else {
                try? FileManager.default.removeItem(at: temp)
                return fetch(checked)
            }
            let destination = PhononModelPaths.archive()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            return fetch(verdict(of: destination))
        } catch let error as URLError {
            let code = error.code.rawValue
            let deferred = PhononModelDownloadPolicy.shouldDefer(urlErrorCode: code)
            let status: PhononModelStatus = deferred ? .deferred : .downloadFailed
            log.info("phonon model status=\(status.rawValue, privacy: .public) urlError=\(code, privacy: .public)")
            return deferred ? .deferred : .missing
        } catch {
            log.info("phonon model status=downloadFailed urlError=\(-1, privacy: .public)")
            return .missing
        }
    }

    /// Re-reads `source.json` before compile. The marker only skips a second unzip.
    private static func extractIfNeeded() -> Bool {
        let expected = PhononModelPin.bundleSHA256
        if let marker = try? String(contentsOf: PhononModelPaths.marker(), encoding: .utf8),
           marker == expected, sourceAccepted() {
            return true
        }
        guard PhononZip.extract(PhononModelPaths.archive(), to: PhononModelPaths.bundle()) else { return false }
        guard sourceAccepted() else { return false }
        do {
            try expected.write(to: PhononModelPaths.marker(), atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        return true
    }

    private static func sourceAccepted() -> Bool {
        guard let data = try? Data(contentsOf: PhononModelPaths.bundle().appendingPathComponent("source.json")),
              PhononModelPin.acceptsSourceJSON(data) else { return false }
        return FileManager.default.fileExists(atPath: PhononModelPaths.bundle().appendingPathComponent("bundle.json").path)
    }
}

/// Allows the GitHub asset redirect only when it stays HTTPS and is not a 40m URL.
/// The redirect may carry the CDN's own query. This type adds no header and no body.
private final class PhononDownloadGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        let folded = url.absoluteString.lowercased()
        if folded.contains("40m") || folded.contains("by-nc") {
            completionHandler(nil)
            return
        }
        var cleaned = request
        cleaned.setValue(nil, forHTTPHeaderField: "Authorization")
        cleaned.httpBody = nil
        completionHandler(cleaned)
    }
}
