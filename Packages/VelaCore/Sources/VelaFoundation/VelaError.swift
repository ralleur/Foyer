import Foundation

/// User-facing error categories. The UI maps these to localized, friendly
/// messages; the technical details stay available for the debug screen.
public enum VelaErrorKind: Sendable, Hashable {
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

public struct VelaError: Error, Sendable, Hashable, CustomStringConvertible {
    public let kind: VelaErrorKind
    /// Technical detail, safe to show in debug UI (already redacted by the caller).
    public let detail: String

    public init(_ kind: VelaErrorKind, detail: String = "") {
        self.kind = kind
        self.detail = detail
    }

    public var description: String {
        detail.isEmpty ? "\(kind)" : "\(kind): \(detail)"
    }

    /// Wraps any error, preserving VelaErrors and mapping URLErrors.
    public static func wrap(_ error: any Error) -> VelaError {
        if let vela = error as? VelaError { return vela }
        if error is CancellationError { return VelaError(.cancelled) }
        if let urlError = error as? URLError {
            return VelaError(urlError.velaKind, detail: "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)")
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let urlError = URLError(URLError.Code(rawValue: ns.code))
            return VelaError(urlError.velaKind, detail: "URLError \(ns.code): \(ns.localizedDescription)")
        }
        return VelaError(.unknown, detail: "\(type(of: error)): \(ns.localizedDescription)")
    }
}

public extension URLError {
    var velaKind: VelaErrorKind {
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
