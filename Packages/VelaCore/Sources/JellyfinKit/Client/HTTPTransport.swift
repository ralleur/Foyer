import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over URLSession so the client can be unit tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public convenience init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 120
        #if !canImport(FoundationNetworking)
        config.waitsForConnectivity = false
        #endif
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.init(session: URLSession(configuration: config))
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        // Linux Foundation lacks the async API; bridge via continuation.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
        #endif
    }
}
