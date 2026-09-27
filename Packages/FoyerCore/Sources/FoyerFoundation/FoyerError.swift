import Foundation

/// User-facing error categories. The UI maps these to localized, friendly
/// messages; the technical details stay available for the debug screen.
public enum FoyerErrorKind: Sendable, Hashable {
    case invalidServerAddress
    case serverUnreachable
    case certificateUntrusted
    case authenticationFailed
    case sessionExpired
    case accessDenied
    case notFound
    case serverError(status: Int)
    case networkInterrupted
    case videoLoadFailed
    case formatUnsupported
    case transcodingFailed
    case subtitlesUnavailable
    case quickConnectUnavailable
    case cancelled
    case unknown

    public var isAuthentication: Bool {
        switch self {
        case .authenticationFailed, .sessionExpired, .accessDenied: true
        default: false
        }
    }
}

public struct FoyerError: Error, Sendable, Hashable, CustomStringConvertible {
    public let kind: FoyerErrorKind
    /// Technical detail, safe to show in debug UI (already redacted by the caller).
    public let detail: String

    public init(_ kind: FoyerErrorKind, detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    public var description: String {
        detail.isEmpty ? "\(kind)" : "\(kind): \(detail)"
    }

    /// Wraps any error, preserving FoyerErrors and mapping URLErrors.
    public static func wrap(_ error: any Error) -> FoyerError {
        if let foyer = error as? FoyerError { return foyer }
        if error is CancellationError { return FoyerError(.cancelled) }
        if let urlError = error as? URLError {
            return FoyerError(urlError.foyerKind, detail: "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)")
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let urlError = URLError(URLError.Code(rawValue: ns.code))
            return FoyerError(urlError.foyerKind, detail: "URLError \(ns.code): \(ns.localizedDescription)")
        }
        return FoyerError(.unknown, detail: "\(type(of: error)): \(ns.localizedDescription)")
    }
}

public extension URLError {
    var foyerKind: FoyerErrorKind {
        switch code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .networkInterrupted
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .resourceUnavailable, .cannotLoadFromNetwork:
            return .serverUnreachable
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return .certificateUntrusted
        case .badURL, .unsupportedURL:
            return .invalidServerAddress
        case .userAuthenticationRequired:
            return .authenticationFailed
        case .fileDoesNotExist:
            return .notFound
        default:
            return .serverUnreachable
        }
    }
}
