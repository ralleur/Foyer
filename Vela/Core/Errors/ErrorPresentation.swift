import Foundation
import VelaFoundation

/// Friendly, localized texts for error categories. Technical details stay in `VelaError.detail`.
struct ErrorPresentation {
    let title: String
    let message: String
    let canRetry: Bool

    init(_ error: any Error) {
        let vela = VelaError.wrap(error)
        switch vela.kind {
        case .invalidServerAddress:
            title = L10n.errorInvalidAddressTitle
            message = L10n.errorInvalidAddressMessage
            canRetry = false
        case .serverUnreachable:
            title = L10n.errorServerUnreachableTitle
            message = L10n.errorServerUnreachableMessage
            canRetry = true
        case .certificateUntrusted:
            title = L10n.errorCertificateTitle
            message = L10n.errorCertificateMessage
            canRetry = false
        case .authenticationFailed:
            title = L10n.errorLoginTitle
            message = L10n.errorLoginMessage
            canRetry = false
        case .sessionExpired:
            title = L10n.errorSessionExpiredTitle
            message = L10n.errorSessionExpiredMessage
            canRetry = false
        case .accessDenied:
            title = L10n.errorAccessDeniedTitle
            message = L10n.errorAccessDeniedMessage
            canRetry = false
        case .notFound:
            title = L10n.errorNotFoundTitle
            message = L10n.errorNotFoundMessage
            canRetry = false
        case .serverError:
            title = L10n.errorServerTitle
            message = L10n.errorServerMessage
            canRetry = true
        case .networkInterrupted:
            title = L10n.errorNetworkTitle
            message = L10n.errorNetworkMessage
            canRetry = true
        case .videoLoadFailed:
            title = L10n.errorVideoTitle
            message = L10n.errorVideoMessage
            canRetry = true
        case .formatUnsupported:
            title = L10n.errorFormatTitle
            message = L10n.errorFormatMessage
            canRetry = false
        case .transcodingFailed:
            title = L10n.errorTranscodingTitle
            message = L10n.errorTranscodingMessage
            canRetry = true
        case .subtitlesUnavailable:
            title = L10n.errorSubtitlesTitle
            message = L10n.errorSubtitlesMessage
            canRetry = false
        case .quickConnectUnavailable:
            title = L10n.errorQuickConnectTitle
            message = L10n.errorQuickConnectMessage
            canRetry = false
        case .cancelled:
            title = ""
            message = ""
            canRetry = false
        case .unknown:
            title = L10n.errorUnknownTitle
            message = L10n.errorUnknownMessage
            canRetry = true
        }
    }
}
