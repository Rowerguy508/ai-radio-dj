import Foundation

/// Why an Apple Music catalog search failed, in terms the listener can act on (#124).
///
/// The app maps MusicKit's own error types to these kinds (`StudioSearchModel`); this file
/// handles the platform-neutral signals (cancellation, URL errors, HTTP status) so the copy is
/// testable on Linux.
public enum SearchFailureKind: Equatable, Sendable, CaseIterable {
    case offline
    case timedOut
    case notAuthorized
    case notSignedIn
    case privacyAcknowledgementRequired
    case noSubscription
    case resultsExpired
    case serviceUnavailable
    /// A newer search or tap replaced this one. Nothing to show.
    case superseded
    case unknown
}

/// Fixed, plain-language copy for the search banner (#104 / #124).
///
/// The banner never shows `localizedDescription`, `debugDescription`, `userInfo`, the search
/// term, song titles or IDs. Every message here is a constant string.
public enum SearchFailureCopy {
    public static let fallback = "Search isn't available right now. Try again."

    /// The banner text for `kind`, or nil when nothing should be shown (`.superseded`).
    public static func message(for kind: SearchFailureKind) -> String? {
        switch kind {
        case .offline:
            "You're offline. Connect to the internet and search again."
        case .timedOut:
            "Search took too long. Check your connection and try again."
        case .notAuthorized:
            "\(AppName.display) needs access to Apple Music to search. You can allow it in Settings."
        case .notSignedIn:
            "Sign in to Apple Music to search for songs."
        case .privacyAcknowledgementRequired:
            "Open the Music app and accept Apple Music's terms, then search again."
        case .noSubscription:
            "Searching Apple Music needs an active Apple Music subscription."
        case .resultsExpired:
            "These results have expired. Search again."
        case .serviceUnavailable:
            "Apple Music isn't responding right now. Try again in a moment."
        case .superseded:
            nil
        case .unknown:
            fallback
        }
    }

    /// Platform-neutral classification. Unknown errors (including cancellation) get the
    /// generic fallback, never their own text.
    public static func kind(for error: Error) -> SearchFailureKind {
        if error is CancellationError { return .unknown }
        let ns = error as NSError
        return kind(domain: ns.domain, code: ns.code)
    }

    /// Known `NSError` domains and codes. Anything else is `.unknown`.
    public static func kind(domain: String, code: Int) -> SearchFailureKind {
        switch domain {
        case "NSURLErrorDomain":
            switch code {
            case -1009, // notConnectedToInternet
                 -1020, // dataNotAllowed
                 -1018, // internationalRoamingOff
                 -1005: // networkConnectionLost
                return .offline
            case -1001: // timedOut
                return .timedOut
            case -1003, // cannotFindHost
                 -1004, // cannotConnectToHost
                 -1011: // badServerResponse
                return .serviceUnavailable
            default:
                return .unknown
            }
        case "ICErrorDomain":
            // iTunesCloud: -7007 is "privacy acknowledgement is required" (Apple forums 682535).
            return code == -7007 ? .privacyAcknowledgementRequired : .unknown
        default:
            return .unknown
        }
    }

    /// Apple Music API HTTP status (`MusicDataRequest.Error.status`).
    public static func kind(httpStatus: Int) -> SearchFailureKind {
        switch httpStatus {
        case 401, 403: .notAuthorized
        case 408: .timedOut
        case 429, 500...599: .serviceUnavailable
        default: .unknown
        }
    }
}
