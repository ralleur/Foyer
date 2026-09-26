import Foundation
import FoyerFoundation

enum FoyerFoundationErrorBridge {
    static func detail(_ error: any Error) -> String {
        let wrapped = FoyerError.wrap(error)
        return Log.redact(wrapped.description)
    }
}
