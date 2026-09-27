import Foundation
import VelaFoundation

enum VelaFoundationErrorBridge {
    static func detail(_ error: any Error) -> String {
        let wrapped = VelaError.wrap(error)
        return Log.redact(wrapped.description)
    }
}
